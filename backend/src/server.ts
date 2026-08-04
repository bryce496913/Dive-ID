import { createClient } from "redis";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { OpenAIMarineIdentificationProvider } from "./provider.js";
import {
  MemoryRateLimitStore,
  QuotaEnforcer,
  RedisRateLimitStore,
  type RateLimitStore,
} from "./rate-limit.js";

async function main() {
  const config = loadConfig();
  if (config.provider !== "openai")
    throw new Error("The standalone server requires AI_PROVIDER=openai");
  let store: RateLimitStore = new MemoryRateLimitStore();
  const redisClient =
    config.rateLimitStore === "redis"
      ? createClient({ url: config.redisURL })
      : undefined;
  if (redisClient) {
    redisClient.on("error", () =>
      console.error(JSON.stringify({ event: "redis_error" })),
    );
    try {
      await redisClient.connect();
    } catch {
      throw new Error(
        "Unable to connect to the configured Redis rate-limit store",
      );
    }
    store = new RedisRateLimitStore(redisClient, config.redisPrefix);
  }
  const provider = new OpenAIMarineIdentificationProvider(
    config.apiKey ?? "",
    config.model,
  );
  const server = createApp({
    provider,
    timeoutMs: config.timeoutMs,
    maxDescriptionLength: config.maxDescriptionLength,
    rateLimitMax: config.rateLimitMax,
    rateLimitWindowMs: config.rateLimitWindowMs,
    quotaEnforcer: new QuotaEnforcer(
      store,
      config.rateLimitMax,
      Math.ceil(config.rateLimitWindowMs / 1000),
      config.installationDailyLimit,
      config.globalDailyRequestLimit,
    ),
    trustProxy: config.trustProxy,
    modelVersion: config.model,
    identificationEnabled: config.identificationEnabled,
    logger: (event) => console.info(JSON.stringify(event)),
  }).listen(config.port, () =>
    console.info(
      JSON.stringify({ event: "server_started", port: config.port }),
    ),
  );
  const shutdown = async () => {
    server.close();
    if (redisClient?.isOpen) await redisClient.quit();
  };
  process.once("SIGTERM", () => void shutdown());
  process.once("SIGINT", () => void shutdown());
}
void main().catch((error: unknown) => {
  console.error(
    error instanceof Error ? error.message : "Backend startup failed",
  );
  process.exitCode = 1;
});
