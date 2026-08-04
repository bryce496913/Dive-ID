import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { OpenAIMarineIdentificationProvider } from "./provider.js";
import {
  DistributedRateLimitStore,
  MemoryRateLimitStore,
  QuotaEnforcer,
} from "./rate-limit.js";
const config = loadConfig();
const store =
  config.rateLimitStore === "redis"
    ? new DistributedRateLimitStore(config.redisURL ?? "")
    : new MemoryRateLimitStore();
if (config.provider !== "openai")
  throw new Error("The standalone server requires AI_PROVIDER=openai");
const provider = new OpenAIMarineIdentificationProvider(
  config.apiKey ?? "",
  config.model,
);
createApp({
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
  logger: (event) => console.info(JSON.stringify(event)),
}).listen(config.port, () =>
  console.info(JSON.stringify({ event: "server_started", port: config.port })),
);
