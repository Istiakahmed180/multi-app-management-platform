import type { Types } from 'mongoose';
import type { Env } from '../../config/env.js';
import { AppError, notFound } from '../../shared/errors.js';
import { dummyPasswordHash, hashPassword, randomToken, sha256, verifyPassword } from '../../shared/crypto.js';
import { Admin, Session, type AdminDoc } from './auth.models.js';

export interface IssuedTokens {
  sessionId: Types.ObjectId;
  accessToken: string;
  refreshToken: string;
  accessExpiresAt: Date;
  refreshExpiresAt: Date;
}

interface ClientInfo {
  ip?: string;
  userAgent?: string;
}

export const PASSWORD_MIN_LENGTH = 12;
const REUSE_GRACE_MS = 30_000;

export class AuthService {
  constructor(private readonly env: Env) {}

  private expiries(now = new Date()) {
    return {
      accessExpiresAt: new Date(now.getTime() + this.env.ACCESS_TOKEN_TTL_MINUTES * 60_000),
      refreshExpiresAt: new Date(now.getTime() + this.env.REFRESH_TOKEN_TTL_DAYS * 86_400_000),
    };
  }

  async login(email: string, password: string, client: ClientInfo): Promise<{ admin: AdminDoc; tokens: IssuedTokens }> {
    const admin = await Admin.findOne({ email: email.toLowerCase() }).select('+passwordHash +failedLoginCount +lockedUntil');
    if (!admin) {
      // Equalize timing with the real verification path to avoid account enumeration.
      await verifyPassword(await dummyPasswordHash(), password);
      throw new AppError('unauthenticated', 'Invalid email or password');
    }
    if (admin.lockedUntil && admin.lockedUntil > new Date()) {
      throw new AppError('account_locked', 'Too many failed attempts. Try again later.');
    }
    const valid = await verifyPassword(admin.passwordHash, password);
    if (!valid || admin.status !== 'active') {
      if (!valid) {
        const failed = (admin.failedLoginCount ?? 0) + 1;
        const lock = failed >= this.env.LOGIN_MAX_FAILED_ATTEMPTS;
        await Admin.updateOne(
          { _id: admin._id },
          {
            $set: {
              failedLoginCount: lock ? 0 : failed,
              lockedUntil: lock ? new Date(Date.now() + this.env.LOGIN_LOCKOUT_MINUTES * 60_000) : null,
            },
          },
        );
      }
      throw new AppError('unauthenticated', 'Invalid email or password');
    }
    await Admin.updateOne({ _id: admin._id }, { $set: { failedLoginCount: 0, lockedUntil: null, lastLoginAt: new Date() } });
    const tokens = await this.createSession(admin._id, client);
    return { admin, tokens };
  }

  async createSession(adminId: Types.ObjectId, client: ClientInfo): Promise<IssuedTokens> {
    const accessToken = randomToken();
    const refreshToken = randomToken();
    const { accessExpiresAt, refreshExpiresAt } = this.expiries();
    const session = await Session.create({
      adminId,
      accessTokenHash: sha256(accessToken),
      refreshTokenHash: sha256(refreshToken),
      accessExpiresAt,
      refreshExpiresAt,
      ip: client.ip ?? null,
      userAgent: client.userAgent ?? null,
    });
    return { sessionId: session._id, accessToken, refreshToken, accessExpiresAt, refreshExpiresAt };
  }

  /** Rotates both tokens. Presenting an already-rotated refresh token revokes the session. */
  async refresh(refreshToken: string, client: ClientInfo): Promise<IssuedTokens> {
    const hash = sha256(refreshToken);
    const now = new Date();
    const reused = await Session.findOne({ previousRefreshTokenHash: hash, revokedAt: null });
    if (reused) {
      // Concurrent refreshes from several tabs share cookies; tolerate a short race window.
      if (reused.rotatedAt && now.getTime() - reused.rotatedAt.getTime() < REUSE_GRACE_MS) {
        throw new AppError('session_expired', 'Refresh token already rotated');
      }
      await Session.updateOne({ _id: reused._id }, { $set: { revokedAt: now, revokedReason: 'refresh_token_reuse' } });
      throw new AppError('session_expired', 'Session is no longer valid');
    }
    const accessToken = randomToken();
    const nextRefresh = randomToken();
    const { accessExpiresAt } = this.expiries(now);
    // Atomic compare-and-swap so concurrent refreshes cannot both succeed.
    const session = await Session.findOneAndUpdate(
      { refreshTokenHash: hash, revokedAt: null, refreshExpiresAt: { $gt: now } },
      {
        $set: {
          accessTokenHash: sha256(accessToken),
          refreshTokenHash: sha256(nextRefresh),
          previousRefreshTokenHash: hash,
          rotatedAt: now,
          accessExpiresAt,
          lastUsedAt: now,
          ip: client.ip ?? null,
          userAgent: client.userAgent ?? null,
        },
      },
      { returnDocument: 'after' },
    );
    if (!session) throw new AppError('session_expired', 'Session is no longer valid');
    const admin = await Admin.findById(session.adminId);
    if (!admin || admin.status !== 'active') {
      await this.revokeSession(session._id, 'admin_disabled');
      throw new AppError('session_expired', 'Session is no longer valid');
    }
    return {
      sessionId: session._id,
      accessToken,
      refreshToken: nextRefresh,
      accessExpiresAt,
      refreshExpiresAt: session.refreshExpiresAt,
    };
  }

  async resolveAccessToken(accessToken: string) {
    const session = await Session.findOne({ accessTokenHash: sha256(accessToken) });
    const now = new Date();
    if (!session || session.revokedAt) throw new AppError('unauthenticated', 'Authentication required');
    if (session.accessExpiresAt <= now || session.refreshExpiresAt <= now) {
      throw new AppError('session_expired', 'Session expired');
    }
    const admin = await Admin.findById(session.adminId);
    if (!admin || admin.status !== 'active') throw new AppError('unauthenticated', 'Authentication required');
    if (now.getTime() - session.lastUsedAt.getTime() > 60_000) {
      await Session.updateOne({ _id: session._id }, { $set: { lastUsedAt: now } });
    }
    return { session, admin };
  }

  async revokeSession(sessionId: Types.ObjectId, reason: string): Promise<void> {
    await Session.updateOne({ _id: sessionId, revokedAt: null }, { $set: { revokedAt: new Date(), revokedReason: reason } });
  }

  async revokeSessionForAdmin(adminId: Types.ObjectId, sessionId: Types.ObjectId): Promise<void> {
    const res = await Session.updateOne(
      { _id: sessionId, adminId, revokedAt: null },
      { $set: { revokedAt: new Date(), revokedReason: 'revoked_by_user' } },
    );
    if (res.matchedCount === 0) throw notFound('Session');
  }

  async revokeAllSessions(adminId: Types.ObjectId, exceptSessionId: Types.ObjectId | null, reason: string): Promise<number> {
    const filter: Record<string, unknown> = { adminId, revokedAt: null };
    if (exceptSessionId) filter._id = { $ne: exceptSessionId };
    const res = await Session.updateMany(filter, { $set: { revokedAt: new Date(), revokedReason: reason } });
    return res.modifiedCount;
  }

  listActiveSessions(adminId: Types.ObjectId) {
    return Session.find({ adminId, revokedAt: null, refreshExpiresAt: { $gt: new Date() } })
      .select('ip userAgent createdAt lastUsedAt refreshExpiresAt')
      .sort({ lastUsedAt: -1 })
      .lean();
  }

  async changePassword(adminId: Types.ObjectId, sessionId: Types.ObjectId, current: string, next: string) {
    const admin = await Admin.findById(adminId).select('+passwordHash');
    if (!admin) throw notFound('Admin');
    if (!(await verifyPassword(admin.passwordHash, current))) {
      throw new AppError('validation_failed', 'Current password is incorrect', [
        { path: 'currentPassword', message: 'Current password is incorrect' },
      ]);
    }
    admin.passwordHash = await hashPassword(next);
    admin.passwordChangedAt = new Date();
    await admin.save();
    return this.revokeAllSessions(adminId, sessionId, 'password_changed');
  }
}
