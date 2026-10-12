import { z } from 'zod';
import { objectIdString } from '../../shared/http.js';
import { paginationQuery, sortQuery } from '../../shared/pagination.js';
import { slugSchema } from '../organizations/organization.schemas.js';
import { APP_ENVIRONMENTS, APP_PLATFORMS, APP_STATUSES } from './app.model.js';

const androidPackage = z
  .string()
  .trim()
  .max(255)
  .regex(/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/, 'Invalid Android package id (e.g. com.example.app)');
const iosBundle = z
  .string()
  .trim()
  .max(255)
  .regex(/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/, 'Invalid iOS bundle id (e.g. com.example.app)');
const httpsUrl = z
  .string()
  .url()
  .max(2048)
  .refine((u) => u.startsWith('https://'), 'Must be an https URL');

const appFields = {
  name: z.string().trim().min(2).max(120),
  slug: slugSchema,
  description: z.string().trim().max(1000),
  platforms: z
    .array(z.enum(APP_PLATFORMS))
    .min(1)
    .max(2)
    .transform((p) => [...new Set(p)]),
  androidPackageId: androidPackage.nullable(),
  iosBundleId: iosBundle.nullable(),
  environment: z.enum(APP_ENVIRONMENTS),
  iconUrl: httpsUrl.nullable(),
};

function requirePlatformIds(
  v: { platforms?: string[]; androidPackageId?: string | null; iosBundleId?: string | null },
  ctx: z.RefinementCtx,
) {
  if (!v.platforms) return;
  if (v.platforms.includes('android') && !v.androidPackageId) {
    ctx.addIssue({ code: 'custom', path: ['androidPackageId'], message: 'Required when Android is a platform' });
  }
  if (v.platforms.includes('ios') && !v.iosBundleId) {
    ctx.addIssue({ code: 'custom', path: ['iosBundleId'], message: 'Required when iOS is a platform' });
  }
}

export const createAppBody = z
  .object({
    orgId: objectIdString,
    name: appFields.name,
    slug: appFields.slug.optional(),
    description: appFields.description.default(''),
    platforms: appFields.platforms,
    androidPackageId: appFields.androidPackageId.default(null),
    iosBundleId: appFields.iosBundleId.default(null),
    environment: appFields.environment.default('production'),
    iconUrl: appFields.iconUrl.default(null),
  })
  .strict()
  .superRefine(requirePlatformIds);

export const updateAppBody = z
  .object({
    name: appFields.name.optional(),
    slug: appFields.slug.optional(),
    description: appFields.description.optional(),
    platforms: appFields.platforms.optional(),
    androidPackageId: appFields.androidPackageId.optional(),
    iosBundleId: appFields.iosBundleId.optional(),
    environment: appFields.environment.optional(),
    iconUrl: appFields.iconUrl.optional(),
  })
  .strict()
  .refine((b) => Object.keys(b).length > 0, 'No fields to update');

export const updateStatusBody = z
  .object({ status: z.enum(APP_STATUSES), reason: z.string().trim().max(500).optional() })
  .strict();

export const listAppsQuery = paginationQuery.extend({
  orgId: objectIdString.optional(),
  search: z.string().trim().max(100).optional(),
  status: z.enum(APP_STATUSES).optional(),
  platform: z.enum(APP_PLATFORMS).optional(),
  environment: z.enum(APP_ENVIRONMENTS).optional(),
  sort: sortQuery(['name', 'createdAt', 'updatedAt'], 'name'),
});

export const presignBody = z
  .object({
    fileName: z.string().trim().min(1).max(200),
    contentType: z.enum(['image/png', 'image/jpeg', 'image/webp', 'image/gif']),
    contentLength: z
      .number()
      .int()
      .positive()
      .max(5 * 1024 * 1024, 'Maximum upload size is 5 MB'),
    purpose: z.enum(['icon', 'banner', 'onboarding', 'logo', 'notification']),
  })
  .strict();
