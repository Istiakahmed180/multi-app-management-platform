import type { Types } from 'mongoose';
import { logger } from '../../config/logger.js';
import { AppUser } from '../app-users/app-user.models.js';
import { recordAudit } from '../audit-logs/audit.service.js';
import type { IntegrationService } from '../integrations/integration.service.js';
import { audienceFilter, tokensFor } from './audience.js';
import { NotificationCampaign } from './campaign.model.js';
import type { Audience } from './campaign.schemas.js';
import type { PushMessage, PushProvider, PushResult } from './push.provider.js';

const LEASE_MS = 5 * 60_000;
const MAX_ATTEMPTS = 5;
const USERS_PER_BATCH = 100;
const MAX_TOKENS_PER_CALL = 500;
const SEND_RETRIES = 3;

type CampaignDoc = NonNullable<Awaited<ReturnType<typeof NotificationCampaign.findOne>>>;

/**
 * Dispatches due campaigns. Work is claimed with an atomic lease in MongoDB, so
 * several API instances can run the worker safely. Progress is checkpointed via
 * `cursor` (last processed AppUser id); a crashed dispatch resumes after the lease
 * expires without re-sending to users already processed.
 */
export class CampaignWorker {
  private timer: NodeJS.Timeout | undefined;
  private running = false;

  constructor(
    private readonly integrations: IntegrationService,
    private readonly sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
  ) {}

  start(intervalMs: number): void {
    this.timer = setInterval(() => void this.tick(), intervalMs);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    while (this.running) await new Promise((r) => setTimeout(r, 50));
  }

  /** Processes due campaigns until none remain. Returns how many were processed. */
  async tick(now = () => new Date()): Promise<number> {
    if (this.running) return 0;
    this.running = true;
    let processed = 0;
    try {
      for (;;) {
        const campaign = await this.claim(now());
        if (!campaign) break;
        processed++;
        try {
          await this.dispatch(campaign);
        } catch (err) {
          logger.error({ err, campaignId: String(campaign._id) }, 'Campaign dispatch failed');
          await NotificationCampaign.updateOne(
            { _id: campaign._id },
            { $set: { lockedUntil: null, lastError: (err as Error).message.slice(0, 1000) } },
          );
        }
      }
    } finally {
      this.running = false;
    }
    return processed;
  }

  private async claim(now: Date): Promise<CampaignDoc | null> {
    const stale = await NotificationCampaign.findOneAndUpdate(
      { status: 'sending', attempts: { $gte: MAX_ATTEMPTS }, $or: [{ lockedUntil: null }, { lockedUntil: { $lte: now } }] },
      { $set: { status: 'failed', completedAt: now, lockedUntil: null, lastError: 'Exceeded maximum dispatch attempts' } },
    );
    if (stale) logger.warn({ campaignId: String(stale._id) }, 'Campaign exceeded dispatch attempts');
    return NotificationCampaign.findOneAndUpdate(
      {
        $or: [
          { status: 'scheduled', scheduledAt: { $lte: now } },
          { status: 'sending', attempts: { $lt: MAX_ATTEMPTS }, $or: [{ lockedUntil: null }, { lockedUntil: { $lte: now } }] },
        ],
      },
      { $set: { status: 'sending', lockedUntil: new Date(now.getTime() + LEASE_MS) }, $inc: { attempts: 1 } },
      { sort: { scheduledAt: 1 }, returnDocument: 'after' },
    );
  }

  private async finish(campaign: CampaignDoc, status: 'sent' | 'partially_failed' | 'failed', lastError: string | null) {
    const done = await NotificationCampaign.findOneAndUpdate(
      { _id: campaign._id },
      { $set: { status, lastError, completedAt: new Date(), lockedUntil: null } },
      { returnDocument: 'after' },
    ).lean();
    await recordAudit(
      {
        action: 'campaign.completed',
        orgId: campaign.orgId,
        appId: campaign.appId,
        targetType: 'campaign',
        targetId: campaign._id,
        metadata: { status, lastError, stats: done?.stats },
      },
      { actorType: 'system' },
    );
  }

  private async sendWithRetry(provider: PushProvider, tokens: string[], message: PushMessage) {
    let pending = tokens;
    const final = new Map<string, PushResult>();
    for (let attempt = 0; attempt < SEND_RETRIES && pending.length > 0; attempt++) {
      if (attempt > 0) await this.sleep(500 * 2 ** attempt);
      const results = await provider.sendMulticast(pending, message);
      for (const r of results) final.set(r.token, r);
      pending = results.filter((r) => !r.ok && r.retryable).map((r) => r.token);
    }
    return [...final.values()];
  }

  private async dispatch(campaign: CampaignDoc): Promise<void> {
    const provider = await this.integrations.pushProviderFor(campaign.appId);
    if (!provider) {
      await this.finish(campaign, 'failed', 'Firebase Cloud Messaging is not configured for this app');
      return;
    }
    const audience = (campaign.toObject() as { audience: Audience }).audience;
    const filter = audienceFilter(campaign.appId, audience);
    if (!campaign.cursor) {
      const targeted = await AppUser.countDocuments(filter);
      await NotificationCampaign.updateOne(
        { _id: campaign._id },
        { $set: { 'stats.targeted': targeted, startedAt: new Date() } },
      );
    }
    const message: PushMessage = {
      title: campaign.title,
      body: campaign.body,
      imageUrl: campaign.imageUrl,
      data: { ...Object.fromEntries((campaign.data as Map<string, string>) ?? []), campaignId: String(campaign._id) },
    };
    let cursor: Types.ObjectId | null = campaign.cursor ?? null;
    const errorCounts = new Map<string, number>();
    for (;;) {
      const users = await AppUser.find(cursor ? { ...filter, _id: { $gt: cursor } } : filter)
        .select('_id pushTokens')
        .sort({ _id: 1 })
        .limit(USERS_PER_BATCH)
        .lean();
      if (users.length === 0) break;
      const tokens = users.flatMap((u) => tokensFor(u, audience));
      let sent = 0;
      let failed = 0;
      const invalid: string[] = [];
      for (let i = 0; i < tokens.length; i += MAX_TOKENS_PER_CALL) {
        const results = await this.sendWithRetry(provider, tokens.slice(i, i + MAX_TOKENS_PER_CALL), message);
        for (const r of results) {
          if (r.ok) sent++;
          else {
            failed++;
            if (r.invalidToken) invalid.push(r.token);
            const code = (r.errorCode ?? 'unknown').replace(/[.$]/g, '_');
            errorCounts.set(code, (errorCounts.get(code) ?? 0) + 1);
          }
        }
      }
      if (invalid.length > 0) {
        await AppUser.updateMany({ appId: campaign.appId }, { $pull: { pushTokens: { token: { $in: invalid } } } });
      }
      cursor = users[users.length - 1]!._id;
      // Checkpoint progress and extend the lease.
      await NotificationCampaign.updateOne(
        { _id: campaign._id },
        {
          $set: { cursor, lockedUntil: new Date(Date.now() + LEASE_MS) },
          $inc: {
            'stats.sent': sent,
            'stats.failed': failed,
            'stats.invalidTokens': invalid.length,
            ...Object.fromEntries([...errorCounts].map(([k, v]) => [`errorSummary.${k}`, v])),
          },
        },
      );
      errorCounts.clear();
    }
    const final = await NotificationCampaign.findById(campaign._id).lean();
    const { sent = 0, failed = 0, targeted = 0 } = final?.stats ?? {};
    let status: 'sent' | 'partially_failed' | 'failed';
    let lastError: string | null = null;
    if (targeted === 0 && sent === 0 && failed === 0) {
      status = 'failed';
      lastError = 'No eligible recipients (users must be active, opted in and have a push token)';
    } else if (failed === 0) status = 'sent';
    else if (sent > 0) status = 'partially_failed';
    else status = 'failed';
    await this.finish(campaign, status, lastError);
  }
}
