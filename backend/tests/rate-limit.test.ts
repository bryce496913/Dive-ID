import { describe, expect, it } from "vitest";
import {
  MemoryRateLimitStore,
  QuotaEnforcer,
  RedisRateLimitStore,
} from "../src/rate-limit.js";

describe("rate limit stores", () => {
  it("reserves capped capacity atomically without growing rejected counters", async () => {
    const store = new MemoryRateLimitStore();
    const results = await Promise.all(
      Array.from({ length: 5 }, () =>
        store.reserveWithinLimit("global", 60, 2),
      ),
    );
    expect(results.filter((value) => value.accepted)).toHaveLength(2);
    expect(results.every((value) => value.count <= 2)).toBe(true);
  });
  it("invokes Redis atomic scripts with normalized prefixed keys", async () => {
    const calls: unknown[] = [];
    const client = {
      eval: async (...args: unknown[]) => {
        calls.push(args);
        return [1, 10];
      },
    };
    const store = new RedisRateLimitStore(client as never, "test-prefix");
    expect((await store.increment("burst:value with spaces", 10)).count).toBe(
      1,
    );
    expect(JSON.stringify(calls)).toContain(
      "test-prefix:quota:burst:value_with_spaces",
    );
  });
  it("rejects invalid Redis script responses", async () => {
    const store = new RedisRateLimitStore({ eval: async () => null } as never);
    await expect(store.increment("x", 2)).rejects.toThrow("invalid response");
  });
});

describe("quota ordering", () => {
  it("does not consume daily or global capacity after burst rejection", async () => {
    const store = new MemoryRateLimitStore();
    const quota = new QuotaEnforcer(store, 1, 60, 1, 1);
    expect(await quota.check("installation", "ip")).toBeUndefined();
    expect(await quota.check("installation", "ip")).toBe("CLIENT_RATE_LIMITED");
    // A different installation and IP sees the already-reserved global unit, proving the rejection did not increment it beyond its cap.
    expect(await quota.check("other", "other-ip")).toBe(
      "SERVER_CAPACITY_REACHED",
    );
  });
  it("allows only two concurrent requests at a global ceiling of two", async () => {
    const quota = new QuotaEnforcer(
      new MemoryRateLimitStore(),
      100,
      60,
      100,
      2,
    );
    const values = await Promise.all(
      Array.from({ length: 5 }, (_, index) =>
        quota.check(`installation-${index}`, `ip-${index}`),
      ),
    );
    expect(values.filter((value) => value === undefined)).toHaveLength(2);
    expect(
      values.filter((value) => value === "SERVER_CAPACITY_REACHED"),
    ).toHaveLength(3);
  });
});
