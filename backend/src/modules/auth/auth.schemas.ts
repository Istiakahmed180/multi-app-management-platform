import { z } from 'zod';
import { PASSWORD_MIN_LENGTH } from './auth.service.js';

export const passwordSchema = z
  .string()
  .min(PASSWORD_MIN_LENGTH, `Password must be at least ${PASSWORD_MIN_LENGTH} characters`)
  .max(256);

export const loginBody = z.object({ email: z.email().max(254), password: z.string().min(1).max(256) }).strict();

export const profileBody = z.object({ name: z.string().trim().min(1).max(120) }).strict();

export const changePasswordBody = z
  .object({ currentPassword: z.string().min(1).max(256), newPassword: passwordSchema })
  .strict()
  .refine((b) => b.currentPassword !== b.newPassword, {
    message: 'New password must differ from the current password',
    path: ['newPassword'],
  });
