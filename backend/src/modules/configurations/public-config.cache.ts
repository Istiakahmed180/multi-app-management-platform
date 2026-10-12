export interface CachedPublicConfig {
  body: string;
  etag: string;
  appId: string;
  orgId: string;
  expiresAt: number;
}

/**
 * Short-lived in-process cache for the public config endpoint. Entries are
 * invalidated on publish/rollback/flag/status changes on this instance; other
 * instances converge within `ttlMs`.
 */
export class PublicConfigCache {
  private readonly entries = new Map<string, CachedPublicConfig>();

  constructor(
    private readonly ttlMs = 30_000,
    private readonly maxEntries = 5_000,
  ) {}

  get(key: string): CachedPublicConfig | undefined {
    const e = this.entries.get(key);
    if (!e) return undefined;
    if (e.expiresAt <= Date.now()) {
      this.entries.delete(key);
      return undefined;
    }
    return e;
  }

  set(key: string, value: Omit<CachedPublicConfig, 'expiresAt'>): void {
    if (this.ttlMs <= 0) return;
    if (this.entries.size >= this.maxEntries) {
      const oldest = this.entries.keys().next().value;
      if (oldest !== undefined) this.entries.delete(oldest);
    }
    this.entries.set(key, { ...value, expiresAt: Date.now() + this.ttlMs });
  }

  /** Invalidates every cached variant (e.g. per-platform) for an app key. */
  invalidate(appKey: string): void {
    for (const k of this.entries.keys()) {
      if (k === appKey || k.startsWith(`${appKey}|`)) this.entries.delete(k);
    }
  }
}
