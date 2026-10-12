import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { Env } from '../../config/env.js';
import { randomToken } from '../../shared/crypto.js';
import { AppError } from '../../shared/errors.js';

export interface PresignedUpload {
  uploadUrl: string;
  publicUrl: string;
  key: string;
  expiresIn: number;
  headers: Record<string, string>;
}

export interface StorageService {
  readonly configured: boolean;
  presignUpload(input: {
    prefix: string;
    fileName: string;
    contentType: string;
    contentLength: number;
  }): Promise<PresignedUpload>;
}

const EXT: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif' };

/** S3-compatible storage (AWS S3, MinIO, Cloudflare R2, ...). Browsers upload directly via presigned PUT. */
export class S3StorageService implements StorageService {
  private readonly client: S3Client | null;

  constructor(private readonly env: Env) {
    this.client =
      env.S3_BUCKET && env.S3_ACCESS_KEY_ID && env.S3_SECRET_ACCESS_KEY
        ? new S3Client({
            region: env.S3_REGION,
            ...(env.S3_ENDPOINT ? { endpoint: env.S3_ENDPOINT } : {}),
            forcePathStyle: env.S3_FORCE_PATH_STYLE,
            credentials: { accessKeyId: env.S3_ACCESS_KEY_ID, secretAccessKey: env.S3_SECRET_ACCESS_KEY },
          })
        : null;
  }

  get configured(): boolean {
    return this.client !== null;
  }

  async presignUpload(input: {
    prefix: string;
    fileName: string;
    contentType: string;
    contentLength: number;
  }): Promise<PresignedUpload> {
    if (!this.client || !this.env.S3_BUCKET) {
      throw new AppError(
        'not_configured',
        'Object storage is not configured. Set S3_BUCKET, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY.',
      );
    }
    // Server-generated keys: the client-provided file name is never used in the path.
    const key = `${input.prefix}/${Date.now()}-${randomToken(9)}.${EXT[input.contentType] ?? 'bin'}`;
    const expiresIn = 300;
    const uploadUrl = await getSignedUrl(
      this.client,
      new PutObjectCommand({
        Bucket: this.env.S3_BUCKET,
        Key: key,
        ContentType: input.contentType,
        ContentLength: input.contentLength,
      }),
      { expiresIn },
    );
    const base =
      this.env.S3_PUBLIC_BASE_URL ??
      (this.env.S3_ENDPOINT
        ? `${this.env.S3_ENDPOINT.replace(/\/$/, '')}/${this.env.S3_BUCKET}`
        : `https://${this.env.S3_BUCKET}.s3.${this.env.S3_REGION}.amazonaws.com`);
    return {
      uploadUrl,
      publicUrl: `${base.replace(/\/$/, '')}/${key}`,
      key,
      expiresIn,
      headers: { 'Content-Type': input.contentType },
    };
  }
}
