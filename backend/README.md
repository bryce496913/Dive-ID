# Dive ID description-identification backend

Node 20+ service for `POST /v1/identifications/description` and `GET /health`. It validates input, calls OpenAI through `MarineIdentificationProvider` with strict JSON-schema output, independently validates/normalizes results, deterministically IDs and deduplicates species, and returns at most ten candidates. The example `gpt-4.1-mini` default balances structured-output capability, latency, and MVP cost; it is not a claim of marine-biology expertise.

## Setup

```bash
cp .env.example .env # never commit .env
npm ci
set -a; source .env; set +a
npm run dev
curl http://localhost:8080/health
npm run format:check && npm run lint && npm run typecheck && npm test && npm run build
```

Startup centrally validates bounded integer ports/timeouts/limits, provider/store/proxy enums, model/key requirements, and distributed-store configuration before listening. Errors name the variable but never its secret value. Use `npm ci --omit=dev` for production-only installation.

Set the iOS build setting `DIVE_ID_API_BASE_URL` to the public HTTPS origin. Simulator development may use `http://localhost:8080`; production must use HTTPS. Provider credentials never belong in iOS.

Deploy behind HTTPS, inject secrets through a secret manager, expose `PORT`, and probe `/health`. Paid calls are guarded by IP, installation burst/daily, and global-daily quotas; failures of the global store fail closed. Memory counters are local/test only. Multi-instance production requires `RATE_LIMIT_STORE=redis` with `REDIS_URL` pointing to the deployment's atomic Redis counter gateway. `TRUST_PROXY` defaults to `none`; select only the documented Express subnet preset matching the deployment so spoofed forwarded headers remain untrusted.

Configure provider-side budget alerts and operational alerts for capacity, rate-limit, timeout, failure-rate, invalid-response, and latency events. Structured logs contain request IDs, outcome categories and latency—not descriptions, credentials, provider bodies, or system prompts. The request ceiling is an MVP guard; token/cost accounting and App Attest are future improvements.

Requests/results are processed in memory and not persisted. Logs contain IDs, timing, outcomes, error categories, and match counts—not descriptions, prompts, provider bodies, or secrets. Provider/platform retention depends on their configuration and agreements.

Limitations: suggestions can be wrong; stable exact-name IDs do not resolve synonyms/taxonomy changes; an installation UUID is a quota signal rather than authentication; no evaluated species database; photo identification is not production-ready. Tests use injected fake transports and incur no provider cost.
