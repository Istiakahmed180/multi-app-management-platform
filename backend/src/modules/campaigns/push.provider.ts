import { cert, deleteApp, initializeApp, type App as FirebaseApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { z } from 'zod';
import { AppError } from '../../shared/errors.js';

export interface PushMessage {
  title: string;
  body: string;
  imageUrl?: string | null;
  data?: Record<string, string>;
}

export interface PushResult {
  token: string;
  ok: boolean;
  errorCode?: string;
  /** The token is invalid/unregistered and should be removed. */
  invalidToken?: boolean;
  /** Transient provider failure; the send may be retried. */
  retryable?: boolean;
}

export interface PushProvider {
  /** Sends to at most 500 tokens. */
  sendMulticast(tokens: string[], message: PushMessage): Promise<PushResult[]>;
  /** Confirms that the credentials can obtain an access token. */
  verify(): Promise<void>;
}

export interface PushProviderFactory {
  /** `cacheKey` must change whenever the credentials change. */
  forCredentials(serviceAccountJson: string, cacheKey: string): PushProvider;
}

export const serviceAccountSchema = z
  .object({
    type: z.literal('service_account'),
    project_id: z.string().min(1),
    client_email: z.email(),
    private_key: z.string().includes('PRIVATE KEY'),
  })
  .passthrough();

const INVALID_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/invalid-recipient',
]);
const RETRYABLE_CODES = new Set([
  'messaging/internal-error',
  'messaging/server-unavailable',
  'messaging/quota-exceeded',
  'messaging/message-rate-exceeded',
  'messaging/device-message-rate-exceeded',
  'app/network-error',
  'app/network-timeout',
]);

class FcmPushProvider implements PushProvider {
  constructor(private readonly app: FirebaseApp) {}

  async sendMulticast(tokens: string[], message: PushMessage): Promise<PushResult[]> {
    if (tokens.length === 0) return [];
    try {
      const res = await getMessaging(this.app).sendEachForMulticast({
        tokens,
        notification: { title: message.title, body: message.body, ...(message.imageUrl ? { imageUrl: message.imageUrl } : {}) },
        data: message.data ?? {},
        android: { priority: 'high' },
        apns: { payload: { aps: { 'mutable-content': message.imageUrl ? 1 : 0 } } },
      });
      return res.responses.map((r, i) => {
        const code = r.error?.code;
        return {
          token: tokens[i]!,
          ok: r.success,
          ...(code ? { errorCode: code, invalidToken: INVALID_TOKEN_CODES.has(code), retryable: RETRYABLE_CODES.has(code) } : {}),
        };
      });
    } catch (err) {
      const code = (err as { code?: string }).code ?? 'unknown';
      return tokens.map((token) => ({
        token,
        ok: false,
        errorCode: code,
        retryable: RETRYABLE_CODES.has(code) || code === 'unknown',
      }));
    }
  }

  async verify(): Promise<void> {
    const credential = this.app.options.credential;
    if (!credential) throw new AppError('bad_request', 'No credential configured');
    try {
      await credential.getAccessToken();
    } catch (err) {
      throw new AppError('upstream_failed', `Firebase rejected the credentials: ${(err as Error).message.slice(0, 200)}`);
    }
  }
}

/** Caches one Firebase app instance per credential version. */
export class FcmPushProviderFactory implements PushProviderFactory {
  private readonly apps = new Map<string, FirebaseApp>();

  forCredentials(serviceAccountJson: string, cacheKey: string): PushProvider {
    let app = this.apps.get(cacheKey);
    if (!app) {
      const sa = serviceAccountSchema.parse(JSON.parse(serviceAccountJson));
      app = initializeApp(
        { credential: cert({ projectId: sa.project_id, clientEmail: sa.client_email, privateKey: sa.private_key }) },
        `amp-${cacheKey}`,
      );
      this.apps.set(cacheKey, app);
    }
    return new FcmPushProvider(app);
  }

  async close(): Promise<void> {
    await Promise.all([...this.apps.values()].map((a) => deleteApp(a)));
    this.apps.clear();
  }
}
