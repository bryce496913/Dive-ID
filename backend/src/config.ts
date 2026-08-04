export interface Config {
  port: number;
  provider: "openai";
  model: string;
  apiKey: string;
  timeoutMs: number;
  maxDescriptionLength: number;
  rateLimitMax: number;
}
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const required = (key: string) => {
    const value = env[key]?.trim();
    if (!value)
      throw new Error(`Missing required environment variable: ${key}`);
    return value;
  };
  if (required("AI_PROVIDER") !== "openai")
    throw new Error("AI_PROVIDER must be openai");
  return {
    port: Number(env.PORT ?? 8080),
    provider: "openai",
    model: required("AI_MODEL"),
    apiKey: required("AI_API_KEY"),
    timeoutMs: Number(env.REQUEST_TIMEOUT_MS ?? 30000),
    maxDescriptionLength: Number(env.MAX_DESCRIPTION_LENGTH ?? 2000),
    rateLimitMax: Number(env.RATE_LIMIT_MAX ?? 30),
  };
}
