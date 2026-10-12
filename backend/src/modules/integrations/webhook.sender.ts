import { isIP } from 'node:net';
import type { Env } from '../../config/env.js';
import { hmacSha256 } from '../../shared/crypto.js';
import { AppError } from '../../shared/errors.js';

export interface WebhookResult {
  ok: boolean;
  status: number | null;
  error?: string;
}

export interface WebhookSender {
  send(url: string, secret: string, event: string, payload: Record<string, unknown>): Promise<WebhookResult>;
}

/** Signature header: `t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>`. */
export function signWebhook(secret: string, body: string, timestamp: number): string {
  return `t=${timestamp},v1=${hmacSha256(secret, `${timestamp}.${body}`)}`;
}

export class HttpWebhookSender implements WebhookSender {
  constructor(private readonly timeoutMs = 5_000) {}

  async send(url: string, secret: string, event: string, payload: Record<string, unknown>): Promise<WebhookResult> {
    const body = JSON.stringify({ event, sentAt: new Date().toISOString(), data: payload });
    const ts = Math.floor(Date.now() / 1000);
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'user-agent': 'AppManagementPlatform-Webhook/1',
          'x-amp-event': event,
          'x-amp-signature': signWebhook(secret, body, ts),
        },
        body,
        redirect: 'manual',
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      return res.ok ? { ok: true, status: res.status } : { ok: false, status: res.status, error: `HTTP ${res.status}` };
    } catch (err) {
      return { ok: false, status: null, error: (err as Error).name === 'TimeoutError' ? 'timeout' : 'network_error' };
    }
  }
}

const PRIVATE_V4 = [
  /^10\./,
  /^127\./,
  /^169\.254\./,
  /^172\.(1[6-9]|2\d|3[01])\./,
  /^192\.168\./,
  /^0\./,
  /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./,
];

/**
 * Basic SSRF guard for admin-supplied webhook URLs. Production deployments should
 * additionally egress through a proxy that blocks internal networks, because DNS
 * can resolve a public hostname to a private address.
 */
export function assertSafeWebhookUrl(raw: string, env: Env): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new AppError('validation_failed', 'Invalid webhook URL', [{ path: 'url', message: 'Invalid URL' }]);
  }
  const devLike = env.NODE_ENV === 'development' || env.NODE_ENV === 'test';
  if (url.protocol !== 'https:' && !(devLike && url.protocol === 'http:')) {
    throw new AppError('validation_failed', 'Webhook URL must use https', [{ path: 'url', message: 'Must use https' }]);
  }
  if (url.username || url.password) {
    throw new AppError('validation_failed', 'Webhook URL must not contain credentials', [
      { path: 'url', message: 'Remove credentials' },
    ]);
  }
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const internal =
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.internal') ||
    (isIP(host) === 4 && PRIVATE_V4.some((r) => r.test(host))) ||
    (isIP(host) === 6 && (host === '::1' || /^f[cd]/i.test(host) || /^fe80/i.test(host)));
  if (internal && !devLike) {
    throw new AppError('validation_failed', 'Webhook URL must be publicly reachable', [
      { path: 'url', message: 'Internal addresses are not allowed' },
    ]);
  }
  return url;
}
