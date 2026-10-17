# Feature Ticket: External Auth and Metering Hook for the Hosted e3d-mcp Server

## Overview

The hosted transport (`e3d-mcp --http`) authenticates callers against a static list of tokens in `E3D_MCP_AUTH_TOKENS`, and it counts usage in local files per token name. That works for three tokens. It cannot support paying customers: keys must be created, revoked and billed elsewhere, and each debate must be charged against a customer's balance.

Add an **external auth and metering hook**: when `E3D_MCP_AUTH_URL` is set, the server asks an external service (1) whether a bearer token is valid and who it belongs to, and (2) whether the caller may spend before each debate, then reports what was actually used. The protocol is small, documented, and open: any billing backend can implement it. The first consumer is the pilot.e3d.ai product on the e3d.ai platform, but nothing in this repository may depend on that platform.

Design rules, in priority order:

1. **Never free, never double.** Usage that happened must reach the billing service exactly once in effect: delivery is *at-least-once* and the service's operations are *idempotent*, so the effect is exactly-once. Usage is never silently dropped. If the server cannot safely record or deliver usage, it stops accepting new billed work.
2. **Fail closed.** If identity or budget cannot be established, the request is refused and no model is called.
3. **Two independent ceilings.** Local caps (`E3D_MCP_DAILY_CALLS`, `E3D_MCP_DAILY_EST_TOKENS`, rate limits) keep working beside the external service, so a bug or compromise in the billing backend cannot make spend unbounded.
4. **Nothing changes when `E3D_MCP_AUTH_URL` is unset**: stdio mode, static-token hosted mode and every existing test behave exactly as before.

## Goals

- A documented HTTP/JSON protocol (`introspect`, `reserve`, `settle`, `release`, `health`) with JSON Schemas, an explicit reservation state machine, and machine-checkable conformance vectors.
- A client with timeouts, size limits, TLS rules, a short-lived cache, abuse limits, and a durable outbox with an atomic-claim delivery protocol.
- Authentication of every `/mcp` request through the hook, sessions bound to the exact token, and authorization (tools, limits) recomputed on every request.
- Metering that survives crashes: intent is persisted before any model runs, partial usage is settled, and orphaned work is reconciled at startup.
- A reference stub service and a conformance runner usable against any implementation.
- Documentation precise enough for a third party to implement the service.

## Non-Goals

- No account system, login, payments, or credit ledger in this repository: those belong to the platform that implements the protocol.
- No change to which tools are exposed over HTTP. The code-writing pipeline tools stay off; the hook may only narrow the operator's `E3D_MCP_HTTP_TOOLS` allowlist, never widen it.
- No new runtime dependencies: Node built-ins only (global `fetch` is used; the package supports Node 18 and up, so feature-detect it and fail clearly at startup if missing).
- No changes to `package.json`, `server.json`, `deploy/**`, or `.github/workflows/**`.

## Running This Spec

```bash
e3d-code docs/e3d-pilot-external-auth-spec.md all --auto-route
```

It is built through e3d-pilot's own pipeline (approval, isolated worktree, independent review, draft PR, human merge). Each phase has a `runner:verify` hook.

## Existing Files (read first)

- `lib/mcp/http.js`: `authenticate`, `parseTokens`, `startHttpServer`: authentication, session binding, rate limits, the tool allowlist, `/healthz`.
- `bin/e3d-mcp`: `toolDebate` (reserve, run, settle), `newHttpConn`, `handle`, the `--doctor` entry, how `usage` is created.
- `lib/mcp/usage.js`: `createUsage` with `reserve`, `settle`, `release` (atomic with a cross-process lock), `safeName` (note: it maps unsafe characters to `_`, so different principals can collide), `worstCase`, `usageFromTranscript`.
- `lib/mcp/doctor.js`, `lib/mcp/redact.js`: diagnostics and secret redaction.
- `tests/mcp-http.sh`, `tests/mcp-usage.sh`, `tests/fixtures/mcp-test-client.mjs`: test style: stub debate binary, throwaway state dirs, no real models.

## Shared Constraints

- Default behavior is unchanged without `E3D_MCP_AUTH_URL`; all existing tests pass untouched.
- Secrets never appear in logs, errors, status output, tool results, or state files: the caller's bearer token, the service token, and anything the service marks sensitive. The cache and the session table are keyed by `sha256(token)`. Logs contain only principal id, tool name, request id, reservation id and outcome, never question text.
- `https:` is required for the service URL; `http:` only for loopback hosts. Redirects are never followed. Certificate verification is never disabled. URLs are joined by appending `/<call>` to the configured base after stripping trailing slashes; a base URL containing credentials, a query or a fragment is rejected.
- Every service call has a timeout (default 3000 ms for `introspect`, `reserve` and `health`; 10000 ms for `settle` and `release`), a request body cap of 16 KB, and a response cap of 64 KB. **Known fields are validated strictly (wrong type, out of range, or malformed means failure); unknown fields are ignored.** Numeric fields are non-negative safe integers within stated bounds; timestamps are RFC 3339 and compared with a stated clock-skew allowance of 60 seconds.
- Principal ids match `^[A-Za-z0-9_.:-]{1,80}$`. Bearer tokens longer than 512 characters or containing characters outside the printable ASCII range are rejected before any service call.
- State directories and files: mode 0700 and 0600, atomic writes (temp file then rename), all under `E3D_MCP_STATE_DIR`.
- Tests assert **ledger effects** (final balances and settlement records in the stub), not counts of HTTP attempts, and grep every state file, outbox record and log for planted secret marker values.
- Node built-ins only; ESM.

## Reservation State Machine (normative)

A reservation has an id and one of these states: `held`, `settled`, `released`, `expired`.

- `reserve` creates `held` (or returns the existing reservation for the same `request_id`; a repeated `request_id` with *different* units is a conflict).
- `settle` with `actual.calls > 0` is **always accepted and charged**, whatever the current state: from `held`, `released` or `expired`. A release or an expiry never erases liability for usage that actually happened. `settle` with `actual.calls == 0` is equivalent to `release`.
- A repeated `settle` with an identical payload returns `ok` and changes nothing; with a different payload it returns `conflict` and changes nothing.
- `release` is only ever sent by the server when actual usage is zero. `release` of a `settled` reservation is a no-op returning `ok`. `release` may name the reservation by `reservation_id` or by `request_id` (for the case where the reserve response was lost).
- `expired` is the final backstop for holds nobody settled or released; the service releases the funds but must still accept and charge a later `settle` with usage.

## Phase 1 - Protocol, Schemas, Stub, Conformance, and Client

<!-- runner:model=codex:gpt-5.4 -->
<!-- pilot:touches=docs/external-auth.md -->
<!-- pilot:touches=docs/external-auth/** -->
<!-- pilot:touches=lib/mcp/external-auth.js -->
<!-- pilot:touches=examples/external-auth-stub.js -->
<!-- pilot:touches=examples/external-auth-conformance.js -->
<!-- pilot:touches=tests/mcp-extauth.sh -->
<!-- pilot:touches=tests/fixtures/** -->
<!-- runner:verify=bash tests/mcp-extauth.sh -->

### Requirements

- Write `docs/external-auth.md` and JSON Schemas in `docs/external-auth/` (one request and one response schema per call). All calls are `POST` with a JSON body to `<E3D_MCP_AUTH_URL>/<call>` (except `health`, a `GET`), authenticated with `Authorization: Bearer <service token>` (from `E3D_MCP_AUTH_SERVICE_TOKEN` or the file named by `E3D_MCP_AUTH_SERVICE_TOKEN_FILE`, which must not be group- or world-readable), and send `X-E3D-Auth-Version: 1`.
  - `introspect`: request `{ "token" }`. Response `{ "active": true, "principal", "tools"?, "limits"?: { "rate_per_min"?, "max_inflight"? }, "expires_at"? }` or `{ "active": false }`.
  - `reserve`: request `{ "principal", "request_id" (UUID), "kind": "debate", "tool", "units": { "calls", "est_tokens" } }`. Response `{ "ok": true, "reservation_id", "expires_at" }` or `{ "ok": false, "code": "insufficient_credits" | "suspended" | "limit_reached" | "unknown_principal" | "conflict", "message" }`.
  - `settle`: request `{ "reservation_id", "actual": { "calls", "est_input_tokens", "est_output_tokens" }, "models": [ { "provider", "model", "calls" } ], "outcome": "ok" | "error" | "timeout" | "orphaned", "duration_ms" }`. Response `{ "ok": true }` or `{ "ok": false, "code": "conflict" }`.
  - `release`: request `{ "reservation_id" }` or `{ "request_id" }`, plus `"reason"`. Response `{ "ok": true }`.
  - `health`: `GET <url>/health` returns 200 `{ "status": "ok" }` when the service can serve; it takes no caller token and is rate-limited by the service.
  - Error classes: HTTP 200 with `ok:false` is a business refusal; any non-2xx status, timeout, malformed or oversized body is a service failure; 401/403 for the service token is a configuration failure and is logged distinctly.
  - The document contains the state machine above, the security properties the service must provide (store only key hashes, constant-time comparison, rate-limit `introspect`, atomic balance checks, no token logging), the guarantees the server provides, the maximum revocation latency (cache TTL plus the duration of an already-running request), and a compatibility section (version header, unknown fields ignored).
- Add `lib/mcp/external-auth.js` exporting `createExternalAuth({ url, serviceToken, fetchImpl, now, env, log })` with `introspect(token)`, `reserve(args)`, `settle(args)`, `release(args)`, `health()`, `stats()` and `validateConfig(env)`. `settle` and `release` here are single attempts that return a result or throw a typed `AuthServiceError` (`unavailable`, `bad-response`, `config`); durable retry is built on top in the next phase.
  - `validateConfig` rejects at startup: a non-URL value; `http:` to a non-loopback host; a missing or shorter than 24 character service token; a token file with loose permissions; a URL with credentials, query or fragment; a missing global `fetch`.
  - `introspect` caches positive results for `E3D_MCP_AUTH_CACHE_SEC` (default 30, bounds 1 to 300) or until `expires_at`, whichever is sooner, and negative results for 5 seconds; at most 5000 entries (oldest evicted); keys are `sha256(token)`; an inactive answer evicts the entry; concurrent introspects of one token share one request; a **global in-flight introspect cap** (default 32, `E3D_MCP_AUTH_MAX_INFLIGHT`) makes excess requests fail fast with `unavailable`.
  - Returned values are re-validated against the schemas (principal pattern, array sizes, integer bounds).
- Add `examples/external-auth-stub.js`: a runnable reference service using only Node built-ins, with in-memory accounts, keys, balances and a reservation ledger implementing the state machine exactly, configurable by environment variables, listening on loopback, with failure-injection switches (slow, 5xx, malformed, oversized, redirect, drop-after-commit). It says at the top that it is an example and test fixture, not production code.
- Add `examples/external-auth-conformance.js <base-url> <service-token>`: runs a set of **conformance vectors** against any implementation (valid and invalid tokens; each refusal code; idempotent `request_id`; conflicting `request_id`; settle after release; settle after expiry; identical and conflicting repeated settle; release by `request_id`; schema conformance of every response) and exits non-zero on the first violation. The stub must pass it, and the test fails if the document lists a code or state transition the vectors do not cover.
- Add `tests/mcp-extauth.sh` (this phase's tests): the conformance run against the stub; the client against the stub for valid and invalid tokens, cache hit within the TTL and re-validation after it (injectable clock), revocation visible after the TTL, concurrent introspects sharing one request, the in-flight cap, reserve success and each refusal; timeouts, 5xx, malformed, oversized and redirecting responses all becoming `AuthServiceError`; `validateConfig` rejections; and a grep proving neither token appears in captured logs.

### Acceptance Criteria

- `bash tests/mcp-extauth.sh` passes, including the conformance run.
- The document, the schemas, the stub and the conformance vectors agree with each other (a test fails on drift).
- Only the listed files are modified and no dependency is added.

## Phase 2 - Durable Settlement Outbox

<!-- runner:model=codex:gpt-5.4 -->
<!-- pilot:touches=lib/mcp/outbox.js -->
<!-- pilot:touches=lib/mcp/external-auth.js -->
<!-- pilot:touches=tests/mcp-extauth.sh -->
<!-- pilot:touches=tests/fixtures/** -->
<!-- runner:verify=bash tests/mcp-extauth.sh -->

### Requirements

- Add `lib/mcp/outbox.js` exporting `createOutbox({ dir, auth, now, log, limits })`. Records are the durable form of `settle`, `release`, and orphan reconciliation calls, delivered with **at-least-once transport and exactly-once effect** (the service's operations are idempotent per the state machine).
  - Layout under `<stateDir>/auth-outbox/`: `pending/`, `claimed/`, `dead/`. A record is one JSON file written atomically, mode 0600, containing the call, its payload, `created_at`, `attempts`, `next_attempt_at`, and a stable `record_id` equal to the idempotency key (`reservation_id` or `request_id` plus the call name).
  - **Atomic claim:** a deliverer moves a record from `pending/` to `claimed/<pid>-<record_id>.json` with `rename`; if the rename fails because another process won, it moves on. A claim older than 5 minutes (`E3D_MCP_OUTBOX_CLAIM_SEC`) is recovered by moving it back to `pending/` (its attempt count is preserved).
  - **Delivery:** after a successful claim, make the call. Delete the record only after the service answers `ok:true`. A `conflict` answer, or a permanent configuration failure, moves the record to `dead/` (never deleted) and logs an error line naming the record id; dead records stop the readiness check from reporting healthy until an operator acts. Transient failures update `attempts` and `next_attempt_at` on the record (exponential backoff 30 s doubling to 15 minutes, with jitter) and return it to `pending/`.
  - A delivery timer runs at startup and every 30 seconds without keeping the process alive; `flush()` delivers everything due and is exported for tests.
  - **No silent drops.** Records are never discarded by age or count. Records older than 72 hours are flagged `stale` in `stats()`. The limit is a **safety bound on pending records** (default 5000, `E3D_MCP_OUTBOX_MAX`): at the bound, `canAccept()` returns false, and the server must refuse new billed work (fail closed) until delivery drains the queue.
  - `stats()` reports counts of pending, claimed, dead and stale records and the oldest age, never payloads.
  - `enqueue(call, payload)` is durable before it returns (fsync of the file and the directory where the platform allows), and enqueuing the same `record_id` twice is a no-op.
- Wire `settle`/`release` through the outbox in `external-auth.js`: a new `settleDurable` and `releaseDurable` that try once immediately and enqueue on any failure; they never throw to the caller.
- Tests (add to `tests/mcp-extauth.sh`): a settle outage (the stub drops or 5xx's) fills the outbox and recovers with every record delivered and the stub's ledger charged exactly once per reservation; a stub that **commits the settle but drops the response** (drop-after-commit) leaves the record pending, redelivery is a no-op in the ledger, and the record is then deleted; two processes delivering one directory concurrently never deliver a record twice in effect and never lose one; a crashed deliverer's stale claim is recovered; a restart with a non-empty outbox delivers at startup; the bound makes `canAccept()` false and recovery makes it true again with nothing dropped; a conflict answer moves a record to `dead/`; stale flagging at 72 hours (injectable clock); every outbox file has mode 0600 and contains no bearer or service token.

### Acceptance Criteria

- `bash tests/mcp-extauth.sh` passes.
- Under every injected failure, the stub's final ledger charges each settled reservation exactly once, and no record is lost.
- The outbox never exceeds its safety bound silently: at the bound the server-facing API refuses new work.

## Phase 3 - Server Integration, Sessions, and Crash-Safe Metering

<!-- runner:model=codex:gpt-5.4 -->
<!-- pilot:touches=lib/mcp/http.js -->
<!-- pilot:touches=bin/e3d-mcp -->
<!-- pilot:touches=lib/mcp/metering.js -->
<!-- pilot:touches=lib/mcp/usage.js -->
<!-- pilot:touches=tests/mcp-extauth.sh -->
<!-- pilot:touches=tests/mcp-usage.sh -->
<!-- pilot:touches=tests/mcp-http.sh -->
<!-- runner:verify=bash tests/mcp-extauth.sh && bash tests/mcp-http.sh && bash tests/mcp-usage.sh -->

### Requirements

- **Startup.** When `E3D_MCP_AUTH_URL` is set (hosted `--http` mode only; setting it without `--http` is an error), `bin/e3d-mcp` validates the configuration and refuses to start on any error. `E3D_MCP_AUTH_TOKENS` is ignored in this mode with one warning line. The outbox and metering-intent recovery run before the server accepts requests.
- **Authentication, per request.** In `lib/mcp/http.js`, with the hook configured, every `/mcp` request (not only `initialize`) is authenticated through `introspect` (cached):
  - before any service call: the bearer token must satisfy the length and character rules, and a per-IP limiter (default 30 unauthenticated attempts per minute, `E3D_MCP_AUTH_IP_PER_MIN`) is applied, so unique-token storms cannot reach the service or bypass the negative cache;
  - inactive: 401 with `www-authenticate: Bearer realm="e3d-mcp"`; service failure: 503 with `retry-after: 5`; no model is called in either case;
  - active: the principal, effective tool allowlist and limits come from the service **on every request** (recomputed from the latest cached answer): the tool allowlist is the intersection of the operator's `E3D_MCP_HTTP_TOOLS` and the service's `tools`; `rate_per_min` and `max_inflight` may lower but never raise the server's own limits;
  - **sessions are bound to the token digest and the principal.** A request on a session id with a different token digest is the existing "unknown session" response. When a token's introspection turns inactive, **only that token's sessions** are dropped; other keys of the same account keep working. State the maximum revocation latency in the document: the cache TTL plus the duration of any request already in flight (which still settles).
- **Metering** in `lib/mcp/metering.js`: `createMetering({ localUsage, external, outbox, log })` with `begin(principal, cost, meta)`, `commit(handle, actual, meta)`, `abort(handle, reason)`, and `recover()`. With no hook configured it delegates to `localUsage` unchanged.
  - **Order and rollback:** external `reserve` first, then local reserve; if external is refused, return its code and message and touch nothing locally; if the local reserve is refused, release the external reservation (durably). **The handle captures the principal** at `begin`; `commit` and `abort` use the captured principal and never re-derive it.
  - **Ambiguous reserve:** if `reserve` times out or fails after the request may have been committed, retry it with the **same `request_id`** (bounded by the call timeout budget) to learn the reservation id; if still unknown, enqueue a durable `release` by `request_id`. Never run the model unless a reservation id was obtained.
  - **Intent before work:** after both reservations succeed and before any model runs, write a metering intent (`<stateDir>/metering-intents/<request_id>.json`, mode 0600: principal, reservation ids, units, started time). It is removed only after the settle record is durably enqueued or delivered.
  - **Actual usage on every outcome:** `commit` settles the usage that actually happened, derived from the transcript, for success, timeout, synthesis failure, malformed output and child-process error. **`release` is used only when actual calls are zero.** If the debate binary produced no transcript, treat calls as zero. Local and external settlement are attempted independently; a failure of one never skips the other, and external failures go to the outbox.
  - **Crash recovery (`recover()`, at startup):** for each intent with no settlement, apply `E3D_MCP_ORPHAN_POLICY` (default `charge`: settle the reserved units with outcome `orphaned`, so a crash can never produce free usage; `release` is available for operators who prefer to under-charge). Orphans are logged and counted in `stats()`.
- `toolDebate` in `bin/e3d-mcp` uses the metering object. A refusal returns an MCP tool error starting `error: billing:` plus the service's message truncated to 200 characters; existing local refusal text is unchanged. When the outbox cannot accept new work, return `error: billing: temporarily unavailable` and run nothing. The result keeps its current `budget` field and gains `billing: { principal, reservation_id }` only when the hook is active.
- **Principal-safe local state.** In `lib/mcp/usage.js`, state files for principals are named `<sanitized>-<first 8 hex of sha256(principal)>.json` so principals that differ only in unsafe characters never share a file; a legacy-named file is read only when the principal is already a safe name (so existing static-token and `local` counters keep working). All usage keys use the service principal.
- **Readiness:** `/readyz` (hook mode only; 404 otherwise) reports the result of a background health probe (`GET /health`, every 15 seconds, result cached), plus outbox state; it **never triggers a service call per request** and reveals no URL or credential. It is 503 when the last probe failed, when dead-letter records exist, or when the outbox is at its bound.
- Tests (extend `tests/mcp-extauth.sh`; run the real server in `--http` mode against the stub with the debate binary stubbed): valid key runs a debate and the stub's ledger is charged the actual use; invalid key 401 and the stub saw no reserve; stub down 503 and no debate binary run; `insufficient_credits` returns the billing error and runs nothing; a refused local cap releases the external reservation; **a debate that times out after answering some rounds is charged those rounds, and a debate that fails before any answer is released**; a **lost reserve response** is recovered with the same `request_id` and never leaves an unreleased hold; **kill the server between reserve and the end of the debate** and verify startup recovery charges per policy (and releases per policy when configured); revoking a key drops only its sessions and a sibling key of the same account keeps working; tools are narrowed by the service and enforced per request; the service's lower rate limit is honored; two keys of one principal share one budget; principals `a:b` and `a_b` never share a local file; unique-token storms are stopped by the IP limiter without reaching the stub; `/readyz` states; outbox bound refuses new work; and without `E3D_MCP_AUTH_URL` the existing static-token behavior is identical (the existing tests pass unmodified).

### Acceptance Criteria

- The three verify scripts pass and every pre-existing MCP test passes without edits.
- With the hook active, no code path calls a model before both reservations succeed and the intent is persisted.
- No test produces a free debate or a double charge in the stub's ledger.
- Neither the caller's token nor the service token appears in logs, tool results, intents, outbox records or state files.

## Phase 4 - Operations, Diagnostics, and Documentation

<!-- runner:model=codex:gpt-5.4 -->
<!-- pilot:touches=bin/e3d-mcp -->
<!-- pilot:touches=lib/mcp/doctor.js -->
<!-- pilot:touches=lib/mcp/usage.js -->
<!-- pilot:touches=lib/mcp/outbox.js -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=docs/external-auth.md -->
<!-- pilot:touches=tests/mcp-extauth.sh -->
<!-- pilot:touches=tests/mcp-usage.sh -->
<!-- pilot:touches=tests/mcp.sh -->
<!-- runner:verify=bash tests/mcp-extauth.sh && bash tests/mcp.sh && bash tests/mcp-usage.sh && bash tests/mcp-http.sh -->

### Requirements

- `e3d_usage` (hook mode) additionally reports `billing: { principal }`, outbox counts (pending, claimed, dead, stale, oldest age), and the count of recovered orphans; never payloads, URLs or credentials.
- `--doctor` reports the hook configuration (URL host only, whether a service token is present, cache TTL, outbox location and counts), whether the service's `health` answers, and any dead or stale outbox records, never the credentials.
- Operator commands, read-only except where stated, all printing only record ids, call names, ages and counts: `e3d-mcp --outbox-status`; `e3d-mcp --outbox-export <file>` (writes the pending and dead records with payloads but no tokens, mode 0600, for reconciliation with the billing service); and `e3d-mcp --outbox-retry-dead <record_id>`, which moves one dead record back to pending after the operator has resolved the conflict (the only mutating command; it requires the exact id).
- README: add a "Hosting with an external auth and metering service" section: when to use it, every environment variable (`E3D_MCP_AUTH_URL`, `E3D_MCP_AUTH_SERVICE_TOKEN`, `E3D_MCP_AUTH_SERVICE_TOKEN_FILE`, `E3D_MCP_AUTH_CACHE_SEC`, `E3D_MCP_AUTH_MAX_INFLIGHT`, `E3D_MCP_AUTH_IP_PER_MIN`, `E3D_MCP_OUTBOX_MAX`, `E3D_MCP_OUTBOX_CLAIM_SEC`, `E3D_MCP_ORPHAN_POLICY`), the fail-closed behavior, how local caps remain a second ceiling, how to run the stub and the conformance runner, the operator commands, and a link to `docs/external-auth.md`. State plainly that the hook checks identity and spend and does not make the code-writing tools safe to expose.
- `docs/external-auth.md`: add an implementer's security checklist (hash stored keys, constant-time comparison, rate-limit `introspect`, atomic balance reservation, the state machine and its idempotency rules, expiry sweeps with retained settle liability, audit logging without secrets) and a runbook section for operators (what each readiness failure means, how to reconcile dead records, what to do after a billing outage).
- Add tests for the operator commands (including that `--outbox-export` output contains no token and has mode 0600, and that `--outbox-retry-dead` refuses anything but an exact id), for `e3d_usage` and `--doctor` output (greps for planted secrets and for the full URL path), and add the new environment variables to the README's table test if one exists.
- Remove nothing and change no defaults.

### Acceptance Criteria

- The four verify scripts pass.
- `--doctor`, `e3d_usage`, and the operator commands expose no credential and no full URL path.
- A reader can implement a compatible service from `docs/external-auth.md`, the schemas and the conformance runner alone.

## After This Ticket (not in scope here)

- The platform side: a pilot product, credit packs, per-account keys and the reserve/settle service on the e3d.ai platform (separate epic, private repository).
- Usage events to an analytics store, dashboards and alerts.
- A hosted account-deletion flow that revokes keys and cancels subscriptions.
- A sandbox design that would allow code-writing tools for customers.
