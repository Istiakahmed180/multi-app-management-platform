import { z } from 'zod';

export const fcmBody = z.object({ serviceAccountJson: z.string().min(50).max(20_000) }).strict();
export const apiKeyBody = z.object({ name: z.string().trim().min(1).max(120) }).strict();
export const webhookBody = z.object({ url: z.string().trim().max(2048) }).strict();
