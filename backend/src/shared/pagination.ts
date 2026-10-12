import { z } from 'zod';

export const paginationQuery = z.object({
  page: z.coerce.number().int().min(1).default(1),
  pageSize: z.coerce.number().int().min(1).max(100).default(20),
});

export type PaginationQuery = z.infer<typeof paginationQuery>;

export interface PageMeta {
  page: number;
  pageSize: number;
  total: number;
  totalPages: number;
}

export function pageMeta(q: PaginationQuery, total: number): PageMeta {
  return { page: q.page, pageSize: q.pageSize, total, totalPages: Math.max(1, Math.ceil(total / q.pageSize)) };
}

export function skip(q: PaginationQuery): number {
  return (q.page - 1) * q.pageSize;
}

/** Builds a sort spec from `field` / `-field`, accepting only whitelisted fields. */
export function sortQuery<const T extends string>(fields: readonly [T, ...T[]], fallback: `${'' | '-'}${T}`) {
  const allowed = [...fields, ...fields.map((f) => `-${f}`)] as [string, ...string[]];
  return z
    .enum(allowed)
    .default(fallback)
    .transform((s): Record<string, 1 | -1> => {
      const desc = s.startsWith('-');
      const field = desc ? s.slice(1) : s;
      return { [field]: desc ? -1 : 1, _id: desc ? -1 : 1 };
    });
}

export function escapeRegex(input: string): string {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
