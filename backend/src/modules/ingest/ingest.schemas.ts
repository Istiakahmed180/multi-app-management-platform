import { z } from 'zod';
import { APP_PLATFORMS } from '../apps/app.model.js';

export const externalUserIdParam = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9_.:@|-]+$/, 'Invalid externalUserId');

const appVersion = z
  .string()
  .trim()
  .max(32)
  .regex(/^\d+(\.\d+){0,3}([-+][0-9A-Za-z.-]+)?$/, 'Invalid app version');
const attributeValue = z.union([z.string().max(500), z.number(), z.boolean(), z.null()]);

export const upsertUserBody = z
  .object({
    email: z.email().max(254).nullable().optional(),
    displayName: z.string().trim().max(120).nullable().optional(),
    platform: z.enum(APP_PLATFORMS).nullable().optional(),
    appVersion: appVersion.nullable().optional(),
    locale: z.string().max(16).nullable().optional(),
    pushOptIn: z.boolean().optional(),
    // Replaces the user's full token set when provided.
    pushTokens: z
      .array(z.object({ token: z.string().min(10).max(4096), platform: z.enum(APP_PLATFORMS) }).strict())
      .max(10)
      .optional(),
    attributes: z
      .record(z.string().regex(/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/), attributeValue)
      .refine((r) => Object.keys(r).length <= 50, 'At most 50 attributes')
      .optional(),
    lastSeenAt: z.iso.datetime().optional(),
  })
  .strict();

export const eventsBody = z
  .object({
    events: z
      .array(
        z
          .object({
            externalUserId: externalUserIdParam,
            type: z.string().regex(/^[a-z][a-z0-9_.]{0,63}$/, 'Event type: lowercase letters, digits, _ and .'),
            occurredAt: z.iso.datetime(),
            platform: z.enum(APP_PLATFORMS).nullable().optional(),
            appVersion: appVersion.nullable().optional(),
            properties: z
              .record(z.string().max(64), attributeValue)
              .refine((r) => Object.keys(r).length <= 30, 'At most 30 properties')
              .optional(),
          })
          .strict(),
      )
      .min(1)
      .max(500),
  })
  .strict();
