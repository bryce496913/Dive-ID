import { z } from "zod";

const integer = (name: string, minimum: number, maximum: number) =>
  z
    .string()
    .default(String(minimum))
    .transform((value, context) => {
      const parsed = Number(value);
      if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) {
        context.addIssue({
          code: "custom",
          message: `${name} must be an integer from ${minimum} through ${maximum}`,
        });
        return z.NEVER;
      }
      return parsed;
    });

const schema = z.object({
  NODE_ENV: z
    .enum(["development", "test", "production"])
    .default("development"),
  PORT: integer("PORT", 1, 65_535).default("8080"),
  AI_PROVIDER: z.enum(["openai", "fake"]).default("fake"),
  AI_MODEL: z
    .string()
    .trim()
    .min(1, "AI_MODEL must not be empty")
    .default("dive-id-fixture"),
  AI_API_KEY: z.string().trim().optional(),
  REQUEST_TIMEOUT_MS: integer("REQUEST_TIMEOUT_MS", 1, 120_000).default(
    "30000",
  ),
  MAX_DESCRIPTION_LENGTH: integer("MAX_DESCRIPTION_LENGTH", 5, 10_000).default(
    "2000",
  ),
  RATE_LIMIT_WINDOW_MS: integer("RATE_LIMIT_WINDOW_MS", 1, 86_400_000).default(
    "60000",
  ),
  RATE_LIMIT_MAX: integer("RATE_LIMIT_MAX", 1, 100_000).default("30"),
  INSTALLATION_DAILY_LIMIT: integer(
    "INSTALLATION_DAILY_LIMIT",
    1,
    100_000,
  ).default("100"),
  GLOBAL_DAILY_REQUEST_LIMIT: integer(
    "GLOBAL_DAILY_REQUEST_LIMIT",
    1,
    10_000_000,
  ).default("10000"),
  RATE_LIMIT_STORE: z.enum(["memory", "redis"]).default("memory"),
  REDIS_URL: z.string().url("REDIS_URL must be a valid URL").optional(),
  TRUST_PROXY: z
    .enum(["none", "loopback", "linklocal", "uniquelocal"])
    .default("none"),
});

export interface Config {
  readonly nodeEnv: "development" | "test" | "production";
  readonly port: number;
  readonly provider: "openai" | "fake";
  readonly model: string;
  readonly apiKey?: string;
  readonly timeoutMs: number;
  readonly maxDescriptionLength: number;
  readonly rateLimitWindowMs: number;
  readonly rateLimitMax: number;
  readonly installationDailyLimit: number;
  readonly globalDailyRequestLimit: number;
  readonly rateLimitStore: "memory" | "redis";
  readonly redisURL?: string;
  readonly trustProxy: false | "loopback" | "linklocal" | "uniquelocal";
}

export function loadConfig(
  env: NodeJS.ProcessEnv = process.env,
): Readonly<Config> {
  const result = schema.safeParse(env);
  if (!result.success) {
    const messages = result.error.issues.map(
      (issue) => `${String(issue.path[0] ?? "environment")}: ${issue.message}`,
    );
    throw new Error(`Invalid configuration: ${messages.join("; ")}`);
  }
  const value = result.data;
  if (value.AI_PROVIDER === "openai" && !value.AI_API_KEY)
    throw new Error(
      "Invalid configuration: AI_API_KEY is required for AI_PROVIDER=openai",
    );
  if (value.RATE_LIMIT_STORE === "redis" && !value.REDIS_URL)
    throw new Error(
      "Invalid configuration: REDIS_URL is required for RATE_LIMIT_STORE=redis",
    );
  if (value.NODE_ENV === "production" && value.RATE_LIMIT_STORE !== "redis")
    throw new Error(
      "Invalid configuration: RATE_LIMIT_STORE must be redis in production",
    );
  return Object.freeze({
    nodeEnv: value.NODE_ENV,
    port: value.PORT,
    provider: value.AI_PROVIDER,
    model: value.AI_MODEL,
    apiKey: value.AI_API_KEY,
    timeoutMs: value.REQUEST_TIMEOUT_MS,
    maxDescriptionLength: value.MAX_DESCRIPTION_LENGTH,
    rateLimitWindowMs: value.RATE_LIMIT_WINDOW_MS,
    rateLimitMax: value.RATE_LIMIT_MAX,
    installationDailyLimit: value.INSTALLATION_DAILY_LIMIT,
    globalDailyRequestLimit: value.GLOBAL_DAILY_REQUEST_LIMIT,
    rateLimitStore: value.RATE_LIMIT_STORE,
    redisURL: value.REDIS_URL,
    trustProxy: value.TRUST_PROXY === "none" ? false : value.TRUST_PROXY,
  });
}
