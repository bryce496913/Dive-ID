import { createHash } from "node:crypto";
import { AppError } from "./errors.js";
import {
  providerResultSchema,
  type DescriptionIdentificationRequest,
  type IdentificationResponse,
  type ProviderResult,
} from "./domain.js";
import type { MarineIdentificationProvider } from "./provider.js";

export function stableSpeciesId(
  scientificName: string,
  commonName: string,
): string {
  const key = (scientificName.trim() || commonName.trim())
    .normalize("NFKC")
    .toLocaleLowerCase("en-US")
    .replace(/\s+/g, " ");
  const bytes = createHash("sha256")
    .update(`dive-id:species:${key}`)
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const h = bytes.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
export function normalizeResult(
  requestId: string,
  raw: ProviderResult,
  model: string,
): IdentificationResponse {
  const parsed = providerResultSchema.safeParse(raw);
  if (!parsed.success)
    throw new AppError(
      "INVALID_PROVIDER_RESPONSE",
      502,
      "invalid provider result",
      parsed.error,
    );
  const seen = new Set<string>();
  const matches = parsed.data.matches
    .sort(
      (a, b) => a.rank - b.rank || (b.matchScore ?? -1) - (a.matchScore ?? -1),
    )
    .filter((m) => {
      const k = (m.scientificName || m.commonName)
        .trim()
        .toLocaleLowerCase("en-US");
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    })
    .slice(0, 10)
    .map((m, index) => ({
      ...m,
      rank: index + 1,
      speciesId: stableSpeciesId(m.scientificName, m.commonName),
    }));
  return {
    requestId,
    matches,
    disclaimer:
      "These are AI-generated identification suggestions and may be inaccurate.",
    generatedAt: new Date().toISOString(),
    modelVersion: model,
  };
}
export async function identify(
  provider: MarineIdentificationProvider,
  request: DescriptionIdentificationRequest,
  timeoutMs: number,
  model: string,
): Promise<IdentificationResponse> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return normalizeResult(
      request.requestId,
      await provider.identifyFromDescription(request, controller.signal),
      model,
    );
  } finally {
    clearTimeout(timer);
  }
}
