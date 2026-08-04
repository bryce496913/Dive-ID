import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const valid = { NODE_ENV: "test", AI_PROVIDER: "fake", AI_MODEL: "fixture" };
describe("configuration validation", () => {
  it.each([
    ["PORT", "abc"],
    ["PORT", "0"],
    ["PORT", "70000"],
    ["REQUEST_TIMEOUT_MS", "-1"],
    ["REQUEST_TIMEOUT_MS", "NaN"],
    ["RATE_LIMIT_MAX", "0"],
    ["RATE_LIMIT_WINDOW_MS", "0"],
    ["GLOBAL_DAILY_REQUEST_LIMIT", "0"],
    ["TRUST_PROXY", "true"],
  ])("identifies invalid %s", (key, value) => {
    expect(() => loadConfig({ ...valid, [key]: value })).toThrow(key);
  });
  it("requires provider credentials without revealing them", () => {
    expect(() =>
      loadConfig({ ...valid, AI_PROVIDER: "openai", AI_MODEL: "gpt-5" }),
    ).toThrow("AI_API_KEY");
  });
  it("requires the distributed store endpoint", () =>
    expect(() => loadConfig({ ...valid, RATE_LIMIT_STORE: "redis" })).toThrow(
      "REDIS_URL",
    ));
  it.each([
    "http://redis.example.com",
    "https://redis.example.com",
    "file:///tmp/redis",
  ])("rejects a non-Redis REDIS_URL: %s", (REDIS_URL) =>
    expect(() =>
      loadConfig({ ...valid, RATE_LIMIT_STORE: "redis", REDIS_URL }),
    ).toThrow("REDIS_URL"),
  );
  it.each(["redis://localhost:6379", "rediss://redis.example.com:6380"])(
    "accepts a supported Redis URL: %s",
    (REDIS_URL) =>
      expect(
        loadConfig({ ...valid, RATE_LIMIT_STORE: "redis", REDIS_URL }).redisURL,
      ).toBe(REDIS_URL),
  );
  it("returns immutable typed values", () => {
    const config = loadConfig(valid);
    expect(config.port).toBe(8080);
    expect(Object.isFrozen(config)).toBe(true);
  });
});
