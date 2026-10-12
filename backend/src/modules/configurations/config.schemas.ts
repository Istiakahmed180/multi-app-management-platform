import { z } from 'zod';
import { paginationQuery } from '../../shared/pagination.js';
import { APP_PLATFORMS } from '../apps/app.model.js';
import { configContentSchema } from './config.content.js';

export const updateDraftBody = z
  .object({
    content: configContentSchema,
    // Optimistic concurrency: reject the write if the draft changed since it was loaded.
    expectedUpdatedAt: z.iso.datetime().optional(),
  })
  .strict();

export const publishBody = z.object({ changeNote: z.string().trim().max(500).default('') }).strict();

export const rollbackBody = z
  .object({ version: z.number().int().positive(), changeNote: z.string().trim().max(500).default('') })
  .strict();

export const listVersionsQuery = paginationQuery;

export const versionParam = z.coerce.number().int().positive();

export const publicConfigQuery = z.object({ platform: z.enum(APP_PLATFORMS).optional() });

export const appKeyParam = z.string().regex(/^app_[A-Za-z0-9]{10,64}$/);
