# Dive ID description-identification backend

Node 20+ service for `POST /v1/identifications/description` and `GET /health`. It validates input, calls OpenAI through `MarineIdentificationProvider` with strict JSON-schema output, independently validates/normalizes results, deterministically IDs and deduplicates species, and returns at most ten candidates. The example `gpt-4.1-mini` default balances structured-output capability, latency, and MVP cost; it is not a claim of marine-biology expertise.

## Setup

```bash
cp .env.example .env # never commit .env
npm install
set -a; source .env; set +a
npm run dev
curl http://localhost:8080/health
npm run format:check && npm run lint && npm run typecheck && npm test && npm run build
```

Required: `AI_PROVIDER=openai`, `AI_MODEL`, `AI_API_KEY`. Optional: `PORT` (8080), `REQUEST_TIMEOUT_MS` (30000), `MAX_DESCRIPTION_LENGTH` (2000), `RATE_LIMIT_MAX` (30/IP/minute), `VERBOSE_LOGGING` (reserved). Missing required settings fail startup.

Set the iOS build setting `DIVE_ID_API_BASE_URL` to the public HTTPS origin. Simulator development may use `http://localhost:8080`; production must use HTTPS. Provider credentials never belong in iOS.

Deploy the production build to a Node/container platform, inject secrets through its secret manager, expose `PORT`, and probe `/health`. Protections include a 16 KiB body limit, bounded timeout, input limits, fixed result maximum, and in-memory per-instance rate limiting. Add distributed limiting, authentication, monitoring, and privacy review before broad release.

Requests/results are processed in memory and not persisted. Logs contain IDs, timing, outcomes, error categories, and match counts—not descriptions, prompts, provider bodies, or secrets. Provider/platform retention depends on their configuration and agreements.

Limitations: suggestions can be wrong; stable exact-name IDs do not resolve synonyms/taxonomy changes; limiting is instance-local; no authentication/evaluated species database; photo identification is not production-ready. Tests use a fake provider and incur no provider cost.
