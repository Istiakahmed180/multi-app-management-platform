import { z } from 'zod';
import { objectIdString } from '../../shared/http.js';
import { paginationQuery } from '../../shared/pagination.js';
import { APP_PLATFORMS } from '../apps/app.model.js';
import { semverSchema } from '../configurations/config.content.js';
import { RELEASE_STATUSES } from './release.model.js';

const storeUrl = z
  .string()
  .url()
  .max(2048)
  .refine((u) => u.startsWith('https://'), 'Must be an https URL');

export const createReleaseBody = z
  .object({
    platform: z.enum(APP_PLATFORMS),
    version: semverSchema,
    buildNumber: z.number().int().min(0).max(2_147_483_647),
    releaseNotes: z.string().trim().max(5000).default(''),
    status: z.enum(RELEASE_STATUSES).default('planned'),
    rolloutPercentage: z.number().min(0).max(100).default(100),
    isMandatory: z.boolean().default(false),
    storeUrl: storeUrl.nullable().default(null),
  })
  .strict();

export const updateReleaseBody = z
  .object({
    releaseNotes: z.string().trim().max(5000).optional(),
    status: z.enum(RELEASE_STATUSES).optional(),
    rolloutPercentage: z.number().min(0).max(100).optional(),
    isMandatory: z.boolean().optional(),
    storeUrl: storeUrl.nullable().optional(),
  })
  .strict()
  .refine((b) => Object.keys(b).length > 0, 'No fields to update');

export const listReleasesQuery = paginationQuery.extend({
  platform: z.enum(APP_PLATFORMS).optional(),
  status: z.enum(RELEASE_STATUSES).optional(),
});

export const releaseIdParam = objectIdString;
