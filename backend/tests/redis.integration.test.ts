import { createClient } from "redis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { RedisRateLimitStore } from "../src/rate-limit.js";

const url = process.env.REDIS_TEST_URL;
describe.skipIf(!url)("Redis rate-limit integration", () => {
  const client = createClient({ url });
  beforeAll(async () => {
    await client.connect();
    await client.flushDb();
  });
  afterAll(async () => {
    if (client.isOpen) await client.quit();
  });
  it("increments atomically, preserves expiry, isolates keys and caps concurrency", async () => {
    const store = new RedisRateLimitStore(client, `integration-${Date.now()}`);
    const first = await store.increment("one", 10);
    const second = await store.increment("one", 10);
    expect([first.count, second.count]).toEqual([1, 2]);
    expect(second.resetAt.getTime()).toBeLessThanOrEqual(
      first.resetAt.getTime() + 1000,
    );
    expect((await store.increment("two", 10)).count).toBe(1);
    const reservations = await Promise.all(
      Array.from({ length: 5 }, () =>
        store.reserveWithinLimit("global", 10, 2),
      ),
    );
    expect(reservations.filter((item) => item.accepted)).toHaveLength(2);
    expect(reservations.every((item) => item.count <= 2)).toBe(true);
  });
});
