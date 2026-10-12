import type { Types } from 'mongoose';
import type { Audience } from './campaign.schemas.js';

/** Users eligible to receive a push: active in the registry, opted in, with at least one token. */
export function audienceFilter(appId: Types.ObjectId, audience: Audience, now = new Date()): Record<string, unknown> {
  const filter: Record<string, unknown> = {
    appId,
    status: 'active',
    pushOptIn: true,
    'pushTokens.0': { $exists: true },
  };
  switch (audience.type) {
    case 'all':
      break;
    case 'platform':
      filter['pushTokens.platform'] = { $in: audience.platforms };
      break;
    case 'active_recently':
      filter.lastSeenAt = { $gte: new Date(now.getTime() - audience.activeWithinDays * 86_400_000) };
      break;
    case 'users':
      filter.externalUserId = { $in: audience.externalUserIds };
      break;
  }
  return filter;
}

/** Restricts tokens to the audience's platforms where relevant. */
export function tokensFor(user: { pushTokens: { token: string; platform: string }[] }, audience: Audience): string[] {
  const tokens =
    audience.type === 'platform'
      ? user.pushTokens.filter((t) => (audience.platforms as string[]).includes(t.platform))
      : user.pushTokens;
  return tokens.map((t) => t.token);
}
