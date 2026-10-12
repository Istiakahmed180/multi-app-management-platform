import { z } from 'zod';
import { objectIdString } from '../../shared/http.js';
import { paginationQuery } from '../../shared/pagination.js';
import { APP_PLATFORMS } from '../apps/app.model.js';
import { CAMPAIGN_STATUSES } from './campaign.model.js';

const httpsUrl = z
  .string()
  .url()
  .max(2048)
  .refine((u) => u.startsWith('https://'), 'Must be an https URL');

export const audienceSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('all') }).strict(),
  z.object({ type: z.literal('platform'), platforms: z.array(z.enum(APP_PLATFORMS)).min(1).max(2) }).strict(),
  z.object({ type: z.literal('active_recently'), activeWithinDays: z.number().int().min(1).max(365) }).strict(),
  z.object({ type: z.literal('users'), externalUserIds: z.array(z.string().min(1).max(128)).min(1).max(1000) }).strict(),
]);
export type Audience = z.infer<typeof audienceSchema>;

// FCM limits the total data payload to 4 KB; keep well under it.
const dataPayload = z
  .record(z.string().regex(/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/), z.string().max(1000))
  .refine((d) => Object.keys(d).length <= 20, 'At most 20 data keys')
  .refine((d) => JSON.stringify(d).length <= 3000, 'Data payload is too large')
  .refine((d) => !Object.keys(d).some((k) => k.startsWith('google') || k === 'from' || k.startsWith('gcm')), 'Reserved data key');

const message = {
  name: z.string().trim().min(1).max(120),
  title: z.string().trim().min(1).max(120),
  body: z.string().trim().min(1).max(1000),
  imageUrl: httpsUrl.nullable(),
  data: dataPayload,
  audience: audienceSchema,
};

export const createCampaignBody = z
  .object({
    ...message,
    imageUrl: message.imageUrl.default(null),
    data: message.data.default({}),
    // When provided, the campaign is scheduled immediately; otherwise it is saved as a draft.
    scheduledAt: z.iso.datetime().optional(),
  })
  .strict();

export const updateCampaignBody = z
  .object({
    name: message.name.optional(),
    title: message.title.optional(),
    body: message.body.optional(),
    imageUrl: message.imageUrl.optional(),
    data: message.data.optional(),
    audience: message.audience.optional(),
  })
  .strict()
  .refine((b) => Object.keys(b).length > 0, 'No fields to update');

export const scheduleBody = z.object({ scheduledAt: z.iso.datetime().optional() }).strict();

export const listCampaignsQuery = paginationQuery.extend({
  status: z.enum(CAMPAIGN_STATUSES).optional(),
  search: z.string().trim().max(100).optional(),
});

export const estimateBody = z.object({ audience: audienceSchema }).strict();

export const idempotencyKeyHeader = z
  .string()
  .min(8)
  .max(128)
  .regex(/^[A-Za-z0-9_.:-]+$/);

export const campaignIdParam = objectIdString;
