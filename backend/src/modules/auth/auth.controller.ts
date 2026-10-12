import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { randomToken, sha256 } from '../../shared/crypto.js';
import { isObjectId, toObjectId } from '../../shared/db.js';
import { AppError, notFound } from '../../shared/errors.js';
import { clientInfo, ok, parse, requireAuth } from '../../shared/http.js';
import { audit, recordAudit } from '../audit-logs/audit.service.js';
import { Admin, Session } from './auth.models.js';
import { changePasswordBody, loginBody, profileBody } from './auth.schemas.js';
import { ACCESS_COOKIE, clearSessionCookies, CSRF_COOKIE, REFRESH_COOKIE, setSessionCookies } from './cookies.js';
import { getProfile } from './profile.service.js';

export function authController({ env, auth }: Deps) {
  return {
    async login(req: Request, res: Response) {
      const body = parse(loginBody, req.body);
      try {
        const { admin, tokens } = await auth.login(body.email, body.password, clientInfo(req));
        const csrfToken = setSessionCookies(res, env, tokens);
        await recordAudit(
          { action: 'auth.login', targetType: 'admin', targetId: admin._id },
          { actorType: 'admin', actorId: admin._id, actorEmail: admin.email },
          req,
        );
        ok(res, { ...(await getProfile(admin._id)), csrfToken });
      } catch (err) {
        if (err instanceof AppError && (err.code === 'unauthenticated' || err.code === 'account_locked')) {
          await recordAudit(
            { action: 'auth.login_failed', metadata: { email: body.email, reason: err.code } },
            { actorType: 'system' },
            req,
          );
        }
        throw err;
      }
    },

    async refresh(req: Request, res: Response) {
      const token: unknown = req.cookies?.[REFRESH_COOKIE];
      if (typeof token !== 'string' || !token) throw new AppError('unauthenticated', 'No refresh token');
      try {
        const tokens = await auth.refresh(token, clientInfo(req));
        const csrfToken = setSessionCookies(res, env, tokens);
        ok(res, { csrfToken, accessExpiresAt: tokens.accessExpiresAt });
      } catch (err) {
        // Keep cookies during the concurrent-rotation grace window: another tab already refreshed them.
        if (!(err instanceof AppError && err.message === 'Refresh token already rotated')) clearSessionCookies(res, env);
        throw err;
      }
    },

    async logout(req: Request, res: Response) {
      const access: unknown = req.cookies?.[ACCESS_COOKIE];
      const refresh: unknown = req.cookies?.[REFRESH_COOKIE];
      const filter =
        typeof access === 'string' && access
          ? { accessTokenHash: sha256(access) }
          : typeof refresh === 'string' && refresh
            ? { refreshTokenHash: sha256(refresh) }
            : null;
      if (filter) {
        const session = await Session.findOneAndUpdate(
          { ...filter, revokedAt: null },
          { $set: { revokedAt: new Date(), revokedReason: 'logout' } },
        );
        if (session) {
          await recordAudit(
            { action: 'auth.logout', targetType: 'session', targetId: session._id },
            { actorType: 'admin', actorId: session.adminId },
            req,
          );
        }
      }
      clearSessionCookies(res, env);
      ok(res, { loggedOut: true });
    },

    async me(req: Request, res: Response) {
      const a = requireAuth(req);
      let csrfToken: unknown = req.cookies?.[CSRF_COOKIE];
      if (typeof csrfToken !== 'string' || !csrfToken) {
        csrfToken = randomToken(24);
        res.cookie(CSRF_COOKIE, csrfToken, { sameSite: 'strict', secure: req.secure, path: '/' });
      }
      ok(res, { ...(await getProfile(a.adminId)), csrfToken });
    },

    async updateProfile(req: Request, res: Response) {
      const a = requireAuth(req);
      const body = parse(profileBody, req.body);
      const admin = await Admin.findByIdAndUpdate(
        a.adminId,
        { $set: { name: body.name } },
        { returnDocument: 'after', runValidators: true },
      );
      await audit(req, { action: 'admin.profile_updated', targetType: 'admin', targetId: a.adminId });
      ok(res, admin?.toJSON());
    },

    async changePassword(req: Request, res: Response) {
      const a = requireAuth(req);
      const body = parse(changePasswordBody, req.body);
      const revoked = await auth.changePassword(a.adminId, a.sessionId, body.currentPassword, body.newPassword);
      await audit(req, {
        action: 'admin.password_changed',
        targetType: 'admin',
        targetId: a.adminId,
        metadata: { revokedSessions: revoked },
      });
      ok(res, { changed: true, revokedSessions: revoked });
    },

    async listSessions(req: Request, res: Response) {
      const a = requireAuth(req);
      const sessions = await auth.listActiveSessions(a.adminId);
      ok(
        res,
        sessions.map((s) => ({
          id: String(s._id),
          ip: s.ip,
          userAgent: s.userAgent,
          createdAt: s.createdAt,
          lastUsedAt: s.lastUsedAt,
          expiresAt: s.refreshExpiresAt,
          current: s._id.equals(a.sessionId),
        })),
      );
    },

    async revokeSession(req: Request, res: Response) {
      const a = requireAuth(req);
      const id = req.params.sessionId;
      if (!isObjectId(id)) throw notFound('Session');
      await auth.revokeSessionForAdmin(a.adminId, toObjectId(id));
      await audit(req, { action: 'auth.session_revoked', targetType: 'session', targetId: id });
      ok(res, { revoked: true });
    },

    async revokeOtherSessions(req: Request, res: Response) {
      const a = requireAuth(req);
      const count = await auth.revokeAllSessions(a.adminId, a.sessionId, 'revoked_by_user');
      await audit(req, { action: 'auth.sessions_revoked', targetType: 'admin', targetId: a.adminId, metadata: { count } });
      ok(res, { revoked: count });
    },
  };
}
