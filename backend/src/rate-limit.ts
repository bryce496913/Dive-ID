import { createHash } from "node:crypto";
import type { RedisClientType } from "redis";

export interface RateLimitResult {
  readonly count: number;
  readonly resetAt: Date;
}
export interface QuotaReservationResult extends RateLimitResult {
  readonly accepted: boolean;
}
export interface RateLimitStore {
  increment(
    key: string,
    windowSeconds: number,
    amount?: number,
  ): Promise<RateLimitResult>;
  reserveWithinLimit(
    key: string,
    windowSeconds: number,
    limit: number,
    amount?: number,
  ): Promise<QuotaReservationResult>;
}

type Entry = { count: number; resetAt: number };
export class MemoryRateLimitStore implements RateLimitStore {
  private readonly entries = new Map<string, Entry>();
  constructor(private readonly now: () => number = Date.now) {}
  async increment(
    key: string,
    windowSeconds: number,
    amount = 1,
  ): Promise<RateLimitResult> {
    const entry = this.current(key, windowSeconds);
    entry.count += amount;
    this.entries.set(key, entry);
    return this.result(entry);
  }
  async reserveWithinLimit(
    key: string,
    windowSeconds: number,
    limit: number,
    amount = 1,
  ): Promise<QuotaReservationResult> {
    const entry = this.current(key, windowSeconds);
    if (entry.count + amount > limit)
      return { accepted: false, ...this.result(entry) };
    entry.count += amount;
    this.entries.set(key, entry);
    return { accepted: true, ...this.result(entry) };
  }
  private current(key: string, windowSeconds: number): Entry {
    const now = this.now();
    const value = this.entries.get(key);
    return !value || value.resetAt <= now
      ? { count: 0, resetAt: now + windowSeconds * 1000 }
      : { ...value };
  }
  private result(entry: Entry): RateLimitResult {
    return { count: entry.count, resetAt: new Date(entry.resetAt) };
  }
}

const incrementScript = `
local count = redis.call('INCRBY', KEYS[1], ARGV[1])
if count == tonumber(ARGV[1]) then redis.call('EXPIRE', KEYS[1], ARGV[2]) end
return {count, redis.call('TTL', KEYS[1])}`;
const reserveScript = `
local current = tonumber(redis.call('GET', KEYS[1]) or '0')
local amount = tonumber(ARGV[1])
if current + amount > tonumber(ARGV[3]) then return {0, current, redis.call('TTL', KEYS[1])} end
local count = redis.call('INCRBY', KEYS[1], amount)
if count == amount then redis.call('EXPIRE', KEYS[1], ARGV[2]) end
return {1, count, redis.call('TTL', KEYS[1])}`;

/** A genuine Redis store. Both scripts apply the increment and first expiry atomically. */
export class RedisRateLimitStore implements RateLimitStore {
  constructor(
    private readonly client: Pick<RedisClientType, "eval">,
    private readonly prefix = "dive-id",
  ) {}
  async increment(
    key: string,
    windowSeconds: number,
    amount = 1,
  ): Promise<RateLimitResult> {
    const response = await this.client.eval(incrementScript, {
      keys: [this.key(key)],
      arguments: [String(amount), String(windowSeconds)],
    });
    const [count, ttl] = parseRedisTuple(response, 2);
    return { count, resetAt: new Date(Date.now() + Math.max(ttl, 0) * 1000) };
  }
  async reserveWithinLimit(
    key: string,
    windowSeconds: number,
    limit: number,
    amount = 1,
  ): Promise<QuotaReservationResult> {
    const response = await this.client.eval(reserveScript, {
      keys: [this.key(key)],
      arguments: [String(amount), String(windowSeconds), String(limit)],
    });
    const [accepted, count, ttl] = parseRedisTuple(response, 3);
    return {
      accepted: accepted === 1,
      count,
      resetAt: new Date(Date.now() + Math.max(ttl, 0) * 1000),
    };
  }
  private key(key: string): string {
    return `${this.prefix}:quota:${key.replace(/[^a-zA-Z0-9:_-]/g, "_")}`;
  }
}
function parseRedisTuple(value: unknown, length: 2): [number, number];
function parseRedisTuple(value: unknown, length: 3): [number, number, number];
function parseRedisTuple(value: unknown, length: number): number[] {
  if (!Array.isArray(value) || value.length !== length)
    throw new Error("rate-limit store returned an invalid response");
  const numbers = value.map(Number);
  if (numbers.some((item) => !Number.isFinite(item)))
    throw new Error("rate-limit store returned an invalid response");
  return numbers;
}

export type QuotaFailure =
  | "CLIENT_RATE_LIMITED"
  | "DAILY_QUOTA_EXCEEDED"
  | "SERVER_CAPACITY_REACHED";
export class QuotaStoreUnavailableError extends Error {}
export class QuotaEnforcer {
  constructor(
    private readonly store: RateLimitStore,
    private readonly burstLimit: number,
    private readonly burstWindowSeconds: number,
    private readonly dailyLimit: number,
    private readonly globalDailyLimit: number,
  ) {}
  async check(
    installationID: string,
    ipAddress = "unknown",
  ): Promise<QuotaFailure | undefined> {
    const installation = digest(installationID);
    const ip = digest(ipAddress);
    try {
      // Rejected burst attempts are intentionally counted, but never consume accepted/paid capacity.
      const [ipBurst, installationBurst] = await Promise.all([
        this.store.increment(`burst:ip:${ip}`, this.burstWindowSeconds),
        this.store.increment(
          `burst:installation:${installation}`,
          this.burstWindowSeconds,
        ),
      ]);
      if (
        ipBurst.count > this.burstLimit ||
        installationBurst.count > this.burstLimit
      )
        return "CLIENT_RATE_LIMITED";
      const daily = await this.store.reserveWithinLimit(
        `installation-daily:${installation}`,
        86_400,
        this.dailyLimit,
      );
      if (!daily.accepted) return "DAILY_QUOTA_EXCEEDED";
      const global = await this.store.reserveWithinLimit(
        "global-provider-daily",
        86_400,
        this.globalDailyLimit,
      );
      if (!global.accepted) return "SERVER_CAPACITY_REACHED";
      return undefined;
    } catch (error) {
      throw new QuotaStoreUnavailableError("quota store unavailable", {
        cause: error,
      });
    }
  }
}
function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 32);
}
