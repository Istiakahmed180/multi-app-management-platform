import type { CookieOptions, Response } from 'express';
import { cookieSecure, type Env } from '../../config/env.js';
import { randomToken } from '../../shared/crypto.js';
import type { IssuedTokens } from './auth.service.js';

export const ACCESS_COOKIE = 'amp_at';
export const REFRESH_COOKIE = 'amp_rt';
export const CSRF_COOKIE = 'amp_csrf';
export const CSRF_HEADER = 'x-csrf-token';

function base(env: Env): CookieOptions {
  return {
    secure: cookieSecure(env),
    sameSite: 'strict',
    ...(env.COOKIE_DOMAIN ? { domain: env.COOKIE_DOMAIN } : {}),
  };
}

/** Sets session cookies and returns the CSRF token the client must echo in `X-CSRF-Token`. */
export function setSessionCookies(res: Response, env: Env, tokens: IssuedTokens): string {
  const csrf = randomToken(24);
  const refreshMaxAge = tokens.refreshExpiresAt.getTime() - Date.now();
  res.cookie(ACCESS_COOKIE, tokens.accessToken, {
    ...base(env),
    httpOnly: true,
    path: '/api',
    maxAge: tokens.accessExpiresAt.getTime() - Date.now(),
  });
  res.cookie(REFRESH_COOKIE, tokens.refreshToken, {
    ...base(env),
    httpOnly: true,
    path: '/api/v1/auth',
    maxAge: refreshMaxAge,
  });
  res.cookie(CSRF_COOKIE, csrf, { ...base(env), httpOnly: false, path: '/', maxAge: refreshMaxAge });
  return csrf;
}

export function clearSessionCookies(res: Response, env: Env): void {
  res.clearCookie(ACCESS_COOKIE, { ...base(env), httpOnly: true, path: '/api' });
  res.clearCookie(REFRESH_COOKIE, { ...base(env), httpOnly: true, path: '/api/v1/auth' });
  res.clearCookie(CSRF_COOKIE, { ...base(env), path: '/' });
}
