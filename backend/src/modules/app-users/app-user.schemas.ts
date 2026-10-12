import { z } from 'zod';
import { paginationQuery, sortQuery } from '../../shared/pagination.js';
import { APP_PLATFORMS } from '../apps/app.model.js';

export const listUsersQuery = paginationQuery.extend({
  search: z.string().trim().max(100).optional(),
  status: z.enum(['active', 'suspended']).optional(),
  platform: z.enum(APP_PLATFORMS).optional(),
  appVersion: z.string().trim().max(32).optional(),
  sort: sortQuery(['createdAt', 'lastSeenAt', 'email'], '-createdAt'),
});

export const activityQuery = paginationQuery;

export const updateUserStatusBody = z
  .object({ status: z.enum(['active', 'suspended']), reason: z.string().trim().max(500).optional() })
  .strict();
