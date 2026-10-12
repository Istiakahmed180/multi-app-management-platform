import { z } from 'zod';
import { APP_PLATFORMS } from '../apps/app.model.js';
import { keySchema, semverSchema } from '../configurations/config.content.js';

const fields = {
  description: z.string().trim().max(500),
  enabled: z.boolean(),
  rolloutPercentage: z.number().int().min(0).max(100),
  platforms: z
    .array(z.enum(APP_PLATFORMS))
    .max(2)
    .transform((p) => [...new Set(p)]),
  minAppVersion: semverSchema.nullable(),
};

export const createFlagBody = z
  .object({
    key: keySchema,
    description: fields.description.default(''),
    enabled: fields.enabled.default(false),
    rolloutPercentage: fields.rolloutPercentage.default(100),
    platforms: fields.platforms.default([]),
    minAppVersion: fields.minAppVersion.default(null),
  })
  .strict();

export const updateFlagBody = z
  .object({
    description: fields.description.optional(),
    enabled: fields.enabled.optional(),
    rolloutPercentage: fields.rolloutPercentage.optional(),
    platforms: fields.platforms.optional(),
    minAppVersion: fields.minAppVersion.optional(),
  })
  .strict()
  .refine((b) => Object.keys(b).length > 0, 'No fields to update');

export const listFlagsQuery = z.object({
  search: z.string().trim().max(64).optional(),
  enabled: z
    .enum(['true', 'false'])
    .transform((v) => v === 'true')
    .optional(),
});

export const flagKeyParam = keySchema;
