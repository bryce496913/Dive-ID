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

Deploy behind HTTPS, inject secrets through a secret manager, expose `PORT`, and probe `/health`. Memory counters are local/test only. Production requires a real Redis server and `RATE_LIMIT_STORE=redis`. `REDIS_URL` accepts only `redis://` or TLS-enabled `rediss://` URLs; HTTP URLs are rejected. `REDIS_PREFIX` isolates environments. One client connects before listening, is reused, and closes on SIGINT/SIGTERM. Store failures fail closed without leaking Redis errors or credentials. Locally, run `docker run --rm -p 6379:6379 redis:7-alpine`; CI supplies Redis 7 without hosted credentials. `TRUST_PROXY` defaults to `none`; select only the documented Express subnet preset matching the deployment.

Quota accounting is staged: incoming attempts encounter IP and installation burst counters first. Burst rejections remain observable but do not consume installation accepted-daily or global provider capacity. Allowed attempts atomically reserve installation daily capacity, then global provider capacity immediately before provider work. Capped Lua reservations reject without incrementing beyond the limit under concurrency. Reservations remain after provider work starts because the request may be billable; provider starts, completions, failures, and rejections are logged separately. Combine these controls with provider-account limits and budget alerts. `IDENTIFICATION_ENABLED=false` is an emergency switch that leaves health operational while preventing provider calls.

Configure provider-side budget alerts and operational alerts for capacity, rate-limit, timeout, failure-rate, invalid-response, and latency events. Structured logs contain request IDs, outcome categories and latency—not descriptions, credentials, provider bodies, or system prompts. The request ceiling is an MVP guard; token/cost accounting and App Attest are future improvements.

Requests/results are processed in memory and not persisted. Logs contain IDs, timing, outcomes, error categories, and match counts—not descriptions, prompts, provider bodies, or secrets. Provider/platform retention depends on their configuration and agreements.

Limitations: suggestions can be wrong; stable exact-name IDs do not resolve synonyms/taxonomy changes; the client-supplied installation UUID is a quota-grouping identifier, not authentication or verified identity, and a modified client can rotate it. IP/global ceilings and provider limits remain necessary. Future hardening can use App Attest, DeviceCheck, server-issued installation credentials, signed short-lived tokens, or user authentication. There is no evaluated species database, and photo identification is not production-ready. Tests use injected fake transports and incur no provider cost.
