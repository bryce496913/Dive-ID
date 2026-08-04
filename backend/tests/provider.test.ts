import { describe, expect, it, vi } from "vitest";
import {
  OpenAIMarineIdentificationProvider,
  SYSTEM_INSTRUCTION,
  type FetchFunction,
} from "../src/provider.js";
import { AppError } from "../src/errors.js";

const request = {
  requestId: "550e8400-e29b-41d4-a716-446655440000",
  description: "Small blue fish with yellow tail",
  context: {},
};
const match = {
  rank: 1,
  commonName: "Palette Surgeonfish",
  scientificName: "Paracanthurus hepatus",
  taxonomicResolution: "species",
  confidenceCategory: "strong",
  matchScore: 0.89,
  explanation: "Blue body and yellow tail fit.",
  distinguishingFeatures: ["Blue body"],
  habitat: "Coral reefs",
  geographicRange: "Indo-Pacific",
  cautions: [],
};
const response = (body: unknown, status = 200) =>
  Promise.resolve(
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    }),
  );

describe("OpenAI adapter", () => {
  it("sends isolated structured input and finds output across items", async () => {
    const transport = vi.fn<FetchFunction>(() =>
      response({
        status: "completed",
        output: [
          { type: "reasoning", content: [] },
          {
            type: "message",
            content: [
              { type: "output_text", text: "not json" },
              {
                type: "output_text",
                text: JSON.stringify({ matches: [match] }),
              },
            ],
          },
        ],
      }),
    );
    const parsed = await new OpenAIMarineIdentificationProvider(
      "secret",
      "gpt-test",
      transport,
    ).identifyFromDescription(request, new AbortController().signal);
    expect(parsed.matches).toHaveLength(1);
    const [url, init] = transport.mock.calls[0]!;
    const body = JSON.parse(String(init?.body));
    expect(url).toBe("https://api.openai.com/v1/responses");
    expect(init?.method).toBe("POST");
    expect((init?.headers as Record<string, string>).authorization).toBe(
      "Bearer secret",
    );
    expect(init?.signal).toBeInstanceOf(AbortSignal);
    expect(body.model).toBe("gpt-test");
    expect(body.input[0]).toEqual({
      role: "system",
      content: SYSTEM_INSTRUCTION,
    });
    expect(body.input[0].content).not.toContain(request.description);
    expect(body.input[1].content).toContain(request.description);
    expect(body.text.format.type).toBe("json_schema");
    expect(body.text.format.strict).toBe(true);
  });
  it("parses a realistic completed response", async () => {
    const transport: FetchFunction = () =>
      response({
        status: "completed",
        output: [
          { type: "reasoning", content: [] },
          {
            type: "message",
            content: [
              {
                type: "output_text",
                text: JSON.stringify({ matches: [match] }),
              },
            ],
          },
        ],
        usage: { input_tokens: 10 },
      });
    const result = await new OpenAIMarineIdentificationProvider(
      "secret",
      "model",
      transport,
    ).identifyFromDescription(request, new AbortController().signal);
    expect(result.matches[0]?.scientificName).toBe(match.scientificName);
  });
  it.each([
    { status: "incomplete", output: [] },
    { status: "completed", output: [] },
    {
      status: "completed",
      output: [{ content: [{ type: "refusal", refusal: "no" }] }],
    },
  ])("rejects refusal, incomplete, and missing output", async (fixture) => {
    await expect(
      new OpenAIMarineIdentificationProvider("secret", "model", () =>
        response(fixture),
      ).identifyFromDescription(request, new AbortController().signal),
    ).rejects.toBeInstanceOf(AppError);
  });
  it.each([
    [400, { error: "bad" }],
    [429, { error: "slow" }],
    [500, { error: "failed" }],
    [502, "<html>bad</html>"],
    [503, ""],
  ])("normalizes provider status %i", async (status, body) => {
    await expect(
      new OpenAIMarineIdentificationProvider("secret", "model", () =>
        response(body, status as number),
      ).identifyFromDescription(request, new AbortController().signal),
    ).rejects.toBeInstanceOf(AppError);
  });
  it("maps an aborted transport without exposing credentials", async () => {
    const controller = new AbortController();
    controller.abort();
    const provider = new OpenAIMarineIdentificationProvider(
      "top-secret",
      "model",
      () => Promise.reject(new DOMException("aborted", "AbortError")),
    );
    await expect(
      provider.identifyFromDescription(request, controller.signal),
    ).rejects.toMatchObject({ code: "IDENTIFICATION_TIMEOUT" });
  });
});
