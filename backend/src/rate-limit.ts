export interface RateLimitResult {
  readonly count: number;
  readonly resetAt: Date;
}
export interface RateLimitStore {
  increment(key: string, windowSeconds: number): Promise<RateLimitResult>;
}

export class MemoryRateLimitStore implements RateLimitStore {
  private readonly entries = new Map<
    string,
    { count: number; resetAt: number }
  >();
  constructor(private readonly now: () => number = Date.now) {}
  async increment(
    key: string,
    windowSeconds: number,
  ): Promise<RateLimitResult> {
    const now = this.now();
    const current = this.entries.get(key);
    const entry =
      !current || current.resetAt <= now
        ? { count: 1, resetAt: now + windowSeconds * 1000 }
        : { ...current, count: current.count + 1 };
    this.entries.set(key, entry);
    return { count: entry.count, resetAt: new Date(entry.resetAt) };
  }
}

/** Adapter for a deployment's Redis-backed counter gateway. The gateway performs
 * atomic INCR+EXPIRE and returns `{count}`; no Redis is needed in local builds. */
export class DistributedRateLimitStore implements RateLimitStore {
  constructor(
    private readonly endpoint: string,
    private readonly transport: typeof fetch = fetch,
  ) {}
  async increment(
    key: string,
    windowSeconds: number,
  ): Promise<RateLimitResult> {
    const response = await this.transport(this.endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key, windowSeconds }),
    });
    if (!response.ok)
      throw new Error("distributed rate-limit store unavailable");
    const body = (await response.json()) as { count?: unknown };
    const count = Number(body.count);
    if (!Number.isFinite(count))
      throw new Error("rate-limit store returned an invalid counter");
    return { count, resetAt: new Date(Date.now() + windowSeconds * 1000) };
  }
}

export type QuotaFailure =
  | "CLIENT_RATE_LIMITED"
  | "DAILY_QUOTA_EXCEEDED"
  | "SERVER_CAPACITY_REACHED";
export class QuotaEnforcer {
  constructor(
    private readonly store: RateLimitStore,
    private readonly burstLimit: number,
    private readonly burstWindowSeconds: number,
    private readonly dailyLimit: number,
    private readonly globalDailyLimit: number,
  ) {}
  async check(installationID: string): Promise<QuotaFailure | undefined> {
    // Fail closed: a store failure must never permit a paid provider call.
    const [burst, daily, global] = await Promise.all([
      this.store.increment(
        `installation:${installationID}:burst`,
        this.burstWindowSeconds,
      ),
      this.store.increment(`installation:${installationID}:daily`, 86_400),
      this.store.increment("global:daily", 86_400),
    ]);
    if (global.count > this.globalDailyLimit) return "SERVER_CAPACITY_REACHED";
    if (daily.count > this.dailyLimit) return "DAILY_QUOTA_EXCEEDED";
    if (burst.count > this.burstLimit) return "CLIENT_RATE_LIMITED";
    return undefined;
  }
}
