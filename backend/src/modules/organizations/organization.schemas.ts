import { z } from 'zod';
import { objectIdString } from '../../shared/http.js';
import { paginationQuery } from '../../shared/pagination.js';
import { ORG_ROLES } from '../../shared/rbac.js';
import { passwordSchema } from '../auth/auth.schemas.js';

export const slugSchema = z
  .string()
  .trim()
  .toLowerCase()
  .min(2)
  .max(64)
  .regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/, 'Use lowercase letters, digits and single hyphens');

export const createOrgBody = z.object({ name: z.string().trim().min(2).max(120), slug: slugSchema.optional() }).strict();
export const updateOrgBody = z.object({ name: z.string().trim().min(2).max(120) }).strict();
export const listOrgsQuery = paginationQuery.extend({ search: z.string().trim().max(100).optional() });

export const memberListQuery = paginationQuery.extend({
  search: z.string().trim().max(100).optional(),
  role: z.enum(ORG_ROLES).optional(),
});

export const updateMemberBody = z
  .object({ role: z.enum(ORG_ROLES).optional(), appIds: z.array(objectIdString).max(500).optional() })
  .strict()
  .refine((b) => b.role !== undefined || b.appIds !== undefined, 'Provide role and/or appIds');

export const createInvitationBody = z
  .object({
    email: z.email().max(254).toLowerCase(),
    role: z.enum(ORG_ROLES),
    appIds: z.array(objectIdString).max(500).default([]),
  })
  .strict();

export const acceptInvitationBody = z
  .object({
    token: z.string().min(20).max(200),
    name: z.string().trim().min(1).max(120).optional(),
    password: passwordSchema.optional(),
  })
  .strict();

export function slugify(input: string): string {
  return (
    input
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 48) || 'org'
  );
}
