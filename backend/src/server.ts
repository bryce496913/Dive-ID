import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { OpenAIMarineIdentificationProvider } from "./provider.js";
const config = loadConfig();
const provider = new OpenAIMarineIdentificationProvider(
  config.apiKey,
  config.model,
);
createApp({
  provider,
  timeoutMs: config.timeoutMs,
  maxDescriptionLength: config.maxDescriptionLength,
  rateLimitMax: config.rateLimitMax,
  modelVersion: config.model,
  logger: (event) => console.info(JSON.stringify(event)),
}).listen(config.port, () =>
  console.info(JSON.stringify({ event: "server_started", port: config.port })),
);
