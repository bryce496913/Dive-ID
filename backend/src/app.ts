import express from "express";
import rateLimit from "express-rate-limit";
import { ZodError } from "zod";
import { requestSchema } from "./domain.js";
import { AppError, publicMessage, type ErrorCode } from "./errors.js";
import type { MarineIdentificationProvider } from "./provider.js";
import { identify } from "./service.js";

export interface AppOptions {
  provider: MarineIdentificationProvider;
  timeoutMs: number;
  maxDescriptionLength: number;
  rateLimitMax: number;
  modelVersion: string;
  logger?: (event: Record<string, unknown>) => void;
}
export function createApp(options: AppOptions) {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "16kb", strict: true }));
  app.get("/health", (_req, res) => res.json({ status: "ok" }));
  const limiter = rateLimit({
    windowMs: 60_000,
    limit: options.rateLimitMax,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    handler: (req, res) =>
      sendError(res, "RATE_LIMITED", 429, requestId(req.body)),
  });
  app.post("/v1/identifications/description", limiter, async (req, res) => {
    const started = Date.now();
    let id = requestId(req.body);
    try {
      const request = requestSchema(options.maxDescriptionLength).parse(
        req.body,
      );
      id = request.requestId;
      const result = await identify(
        options.provider,
        request,
        options.timeoutMs,
        options.modelVersion,
      );
      options.logger?.({
        requestId: id,
        status: "success",
        durationMs: Date.now() - started,
        matchCount: result.matches.length,
      });
      res.json(result);
    } catch (error) {
      const mapped = mapError(error);
      options.logger?.({
        requestId: id,
        status: "error",
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
