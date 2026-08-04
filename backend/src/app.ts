import express from "express";
import rateLimit from "express-rate-limit";
import { ZodError } from "zod";
import { requestSchema } from "./domain.js";
import { AppError, publicMessage, type ErrorCode } from "./errors.js";
import type { MarineIdentificationProvider } from "./provider.js";
import { identify } from "./service.js";
import type { QuotaEnforcer } from "./rate-limit.js";

export interface AppOptions {
  provider: MarineIdentificationProvider;
  timeoutMs: number;
  maxDescriptionLength: number;
  rateLimitMax: number;
  rateLimitWindowMs?: number;
  quotaEnforcer?: QuotaEnforcer;
  trustProxy?: false | "loopback" | "linklocal" | "uniquelocal";
  modelVersion: string;
  identificationEnabled?: boolean;
  logger?: (event: Record<string, unknown>) => void;
}
export function createApp(options: AppOptions) {
  const app = express();
  app.disable("x-powered-by");
  if (options.trustProxy) app.set("trust proxy", options.trustProxy);
  app.use(express.json({ limit: "16kb", strict: true }));
  app.get("/health", (_req, res) => res.json({ status: "ok" }));
  const ipLimiter = rateLimit({
    windowMs: options.rateLimitWindowMs ?? 60_000,
    limit: options.rateLimitMax,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    handler: (req, res) =>
      sendError(res, "RATE_LIMITED", 429, requestId(req.body)),
  });
  app.post("/v1/identifications/description", ipLimiter, async (req, res) => {
    const started = Date.now();
    let id = requestId(req.body);
    try {
      if (options.identificationEnabled === false) {
        options.logger?.({
          requestId: id,
          event: "identification_rejected",
          reason: "kill_switch",
        });
        sendError(res, "IDENTIFICATION_DISABLED", 503, id);
        return;
      }
      const parsedRequest = requestSchema(options.maxDescriptionLength).parse(
        req.body,
      );
      id = parsedRequest.requestId;
      const installation =
        req.header("x-dive-id-installation") ??
        "00000000-0000-4000-8000-000000000000";
      if (!zUUID.safeParse(installation).success) {
        sendError(res, "INVALID_CLIENT_IDENTIFIER", 400, id);
        return;
      }
      if (options.quotaEnforcer) {
        let failure;
        try {
          failure = await options.quotaEnforcer.check(installation, req.ip);
        } catch {
          options.logger?.({
            requestId: id,
            event: "quota_store_failure",
            status: "rejected",
          });
          failure = "SERVER_CAPACITY_REACHED" as const;
        }
        if (failure) {
          options.logger?.({
            requestId: id,
            event: "identification_rejected",
            status: "rejected",
            errorCode: failure,
          });
          sendError(
            res,
            failure,
            failure === "CLIENT_RATE_LIMITED" ? 429 : 503,
            id,
          );
          return;
        }
      }
      const request = parsedRequest;
      options.logger?.({ requestId: id, event: "provider_call_started" });
      const result = await identify(
        options.provider,
        request,
        options.timeoutMs,
        options.modelVersion,
      );
      options.logger?.({
        requestId: id,
        status: "success",
        event: "provider_call_completed",
        durationMs: Date.now() - started,
        matchCount: result.matches.length,
      });
      res.json(result);
    } catch (error) {
      const mapped = mapError(error);
      options.logger?.({
        requestId: id,
        status: "error",
        event: "provider_call_failed",
        durationMs: Date.now() - started,
        errorCode: mapped.code,
      });
      sendError(res, mapped.code, mapped.status, id);
    }
  });
  app.use(
    (
      error: unknown,
      req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      const tooLarge =
        error instanceof Error &&
        "type" in error &&
        (error as { type?: string }).type === "entity.too.large";
      sendError(
        res,
        "INVALID_REQUEST",
        tooLarge ? 413 : 400,
        requestId(req.body),
      );
    },
  );
  return app;
}
const zUUID = {
  safeParse: (value: string) => ({
    success:
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
        value,
      ),
  }),
};
function requestId(body: unknown): string {
  return typeof body === "object" &&
    body !== null &&
    "requestId" in body &&
    typeof body.requestId === "string"
    ? body.requestId
    : "unknown";
}
function mapError(error: unknown): { code: ErrorCode; status: number } {
  if (error instanceof AppError) return error;
  if (error instanceof ZodError) {
    const marker = error.issues.find(
      (i) =>
        i.message === "DESCRIPTION_TOO_SHORT" ||
        i.message === "DESCRIPTION_TOO_LONG",
    )?.message as ErrorCode | undefined;
    return { code: marker ?? "INVALID_REQUEST", status: 400 };
  }
  return { code: "INTERNAL_ERROR", status: 500 };
}
function sendError(
  res: express.Response,
  code: ErrorCode,
  status: number,
  id: string,
) {
  res
    .status(status)
    .json({ error: { code, message: publicMessage(code), requestId: id } });
}
