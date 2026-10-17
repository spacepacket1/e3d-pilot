# Debate

**Prompt version:** v2

**Question:** Review this implementation spec critically. It will be built phase by phase by an AI code runner, reviewed by a different model, then merged by a human. Find real problems, not style: contradictions, missing acceptance criteria, ambiguity that would let an implementer build the wrong thing, security holes (this sits between paying customers and our model spend), races between reserve/settle/release, failure modes that could give free usage or double-charge, tests that would pass while the behavior is wrong, and scope that is too big or too small. Check especially: fail-closed behavior; the outbox (exactly-once delivery, two processes, restart); the cache and revocation timing; session binding when a key is revoked; the interaction with the existing local usage.js reserve/settle/release (order, rollback, the principal used); whether the protocol is implementable by a third party from docs alone; and whether the three phases are independently verifiable.

Rules: (1) list concrete defects with the exact section and a proposed fix; (2) separate must-fix from nice-to-have; (3) end with a clear recommendation: ready to build, or fix first.

THE SPEC:
-----
# Feature Ticket: External Auth and Metering Hook for the Hosted e3d-mcp Server

## Overview

The hosted transport (`e3d-mcp --http`) authenticates callers against a static list of tokens in `E3D_MCP_AUTH_TOKENS`, and it counts usage in local files per token name. That works for three tokens. It cannot support paying customers: keys must be created, revoked and billed elsewhere, and each debate must be charged against a customer's balance.

Add an **external auth and metering hook**: when `E3D_MCP_AUTH_URL` is set, the server asks an external service (1) whether a bearer token is valid and who it belongs to, and (2) whether the caller may spend before each debate, then reports what was actually used. The protocol is small, documented, and open: any billing backend can implement it. The first consumer is the pilot.e3d.ai product on the e3d.ai platform (accounts and credits live there), but nothing in this repository may depend on that platform.

The hook **fails closed**: if the external service cannot be reached or says no, the request is refused and no model is called. Local caps (`E3D_MCP_DAILY_CALLS`, `E3D_MCP_DAILY_EST_TOKENS`, rate limits, the global ceiling) keep working as a second, independent ceiling, so a bug or compromise in the billing backend cannot make spend unbounded.

Nothing changes when `E3D_MCP_AUTH_URL` is unset: stdio mode, static-token hosted mode, and every existing test behave exactly as before.

## Goals

- A documented HTTP/JSON protocol with four calls: `introspect`, `reserve`, `settle`, `release`.
- A client for it in the server, with timeouts, size limits, TLS rules, a short-lived cache, and a durable retry outbox for settle and release.
- Authentication of every `/mcp` request through the hook when configured (revoked keys stop working within the cache time), with the caller's principal, tool allowlist and limits taken from the service.
- Metering: each debate reserves credits externally, then locally, runs, then settles both to actual use; refusals cost nothing; failures release.
- A reference stub service in `examples/` and a test suite that runs the real server against it.
- Documentation precise enough that someone else can implement the service.

## Non-Goals

- No account system, login, payments, or credit ledger in this repository: those belong to the platform that implements the protocol.
- No change to which tools are exposed over HTTP. The code-writing pipeline tools stay off (`E3D_MCP_HTTP_TOOLS` default is unchanged); the hook may only narrow the allowed tools, never widen beyond the operator's `E3D_MCP_HTTP_TOOLS`.
- No new runtime dependencies: Node built-ins only (global `fetch` is available; the package supports Node 18 and up, so feature-detect and fail clearly if it is missing).
- No changes to `package.json`, `server.json`, `deploy/**`, or `.github/workflows/**` (the release and deployment kit are updated separately).

## Running This Spec

```bash
e3d-code docs/e3d-pilot-external-auth-spec.md all --auto-route
```

It is built through e3d-pilot's own pipeline (approval, isolated worktree, independent review, draft PR, human merge). Each phase has a `runner:verify` hook.

## Existing Files (read first)

- `lib/mcp/http.js`: `authenticate`, `parseTokens`, `startHttpServer`: where requests are authenticated, sessions are bound to a principal, rate limits and the tool allowlist are applied.
- `bin/e3d-mcp`: `toolDebate` (budget reserve and settle), `newHttpConn`, `handle`, how `usage` is created.
- `lib/mcp/usage.js`: `createUsage` with `reserve`, `settle`, `release` (atomic, cross-process lock), `worstCase`, `usageFromTranscript`, `jobCost`.
- `lib/mcp/redact.js`: how secrets are removed from logs and errors.
- `tests/mcp-http.sh`, `tests/mcp-usage.sh`, `tests/fixtures/mcp-test-client.mjs`: test style: stub debate binary, throwaway state dirs, no real models.
- `docs/mcp-agent-instructions.md` and the README MCP section: documentation conventions.

## Shared Constraints

- Default behavior is unchanged without `E3D_MCP_AUTH_URL`; all existing tests pass untouched.
- Fail closed: any uncertainty about identity or budget means refuse. Never serve a request free because the billing service is down.
- Secrets never appear in logs, errors, status output, or state files: the caller's bearer token, the service token, and anything from the service marked sensitive. The cache is keyed by a SHA-256 of the token, never the token. Logs may contain the principal id, tool name, reservation id and outcome only.
- `https:` is required for the service URL; `http:` is allowed only for loopback hosts (`127.0.0.1`, `::1`, `localhost`) so tests and same-machine deployments work. Redirects are never followed. TLS certificate verification is never disabled.
- Every call to the service has a timeout (default 3000 ms for introspect and reserve, 10000 ms for settle and release), a request body cap, and a response size cap of 64 KB; responses are parsed strictly and any unexpected shape is treated as a failure.
- Principal ids from the service must match `^[A-Za-z0-9_.:-]{1,80}$`; anything else is rejected.
- Time-bounded state only: the cache and the outbox have maximum sizes and ages so a hostile or buggy service cannot exhaust memory or disk.
- Node built-ins only; ESM; atomic file writes (temp file then rename); file mode 0600 for any state file.

## Phase 1 - External Auth Client and Protocol

<!-- runner:model=codex:gpt-5.4 -->
<!-- pilot:touches=lib/mcp/external-auth.js -->
<!-- pilot:touches=docs/external-auth.md -->
<!-- pilot:touches=examples/external-auth-stub.js -->
<!-- pilot:touches=tests/mcp-extauth.sh -->
<!-- pilot:touches=tests/fixtures/** -->
<!-- runner:verify=bash tests/mcp-extauth.sh -->

### Requirements

- Write `docs/external-auth.md`, the protocol reference. All calls are `POST` with a JSON body and `Content-Type: application/json` to `<E3D_MCP_AUTH_URL>/<call>`, authenticated with `Authorization: Bearer <service token>` (from `E3D_MCP_AUTH_SERVICE_TOKEN` or the file named by `E3D_MCP_AUTH_SERVICE_TOKEN_FILE`; the file must not be group- or world-readable), and send `X-E3D-Auth-Version: 1`. Define:
  - `introspect`: request `{ "token": "<caller bearer token>" }`. Response `{ "active": true, "principal": "<id>", "tools": ["e3d_debate", ...], "limits": { "rate_per_min": 30, "max_inflight": 2 }, "expires_at": "<RFC 3339>" }` or `{ "active": false }`. `tools`, `limits` and `expires_at` are optional.
  - `reserve`: request `{ "principal", "request_id", "kind": "debate", "tool", "units": { "calls": <int>, "est_tokens": <int> } }`. Response `{ "ok": true, "reservation_id": "<id>", "expires_at": "<RFC 3339>" }` or `{ "ok": false, "code": "insufficient_credits" | "suspended" | "limit_reached" | "unknown_principal", "message": "<short text>" }`. `request_id` is a UUID chosen by the server; the service must treat a repeated `request_id` as the same reservation (idempotent).
  - `settle`: request `{ "reservation_id", "actual": { "calls", "est_input_tokens", "est_output_tokens" }, "models": [ { "provider", "model", "calls" } ], "outcome": "ok" | "error" | "timeout", "duration_ms" }`. Response `{ "ok": true }`. Idempotent by `reservation_id`; settling an unknown or already settled reservation returns `{ "ok": true }` and changes nothing.
  - `release`: request `{ "reservation_id", "reason" }`. Response `{ "ok": true }`. Idempotent.
  - Error behavior: HTTP 200 with `ok:false` is a business refusal; any non-2xx status, timeout, malformed body, or oversized body is a service failure. HTTP 401/403 for the service token itself is a configuration failure and is reported distinctly in logs.
  - The document states the security properties the service must provide (hash stored keys, constant-time compare, rate-limit introspect, never log tokens) and the guarantees the server provides (fail closed, idempotency keys, bounded cache, durable settle).
- Add `lib/mcp/external-auth.js` exporting `createExternalAuth({ url, serviceToken, fetchImpl, now, env, stateDir, log })` with `introspect(token)`, `reserve(...)`, `settle(...)`, `release(...)`, `flushOutbox()`, `stats()`, and `validateConfig(env)`.
  - `validateConfig` rejects (with a clear message, at startup): a non-URL value; `http:` to a non-loopback host; a missing service token; a service token shorter than 24 characters; a token file with loose permissions; a URL with credentials in it.
  - `introspect` returns `{ active, principal, tools, limits, expiresAt }` or `{ active: false }` or throws a typed `AuthServiceError` (`unavailable`, `bad-response`, `config`). Positive results are cached for `E3D_MCP_AUTH_CACHE_SEC` (default 30, minimum 1, maximum 300) or until `expires_at`, whichever is sooner; negative results for 5 seconds; at most 5000 entries (oldest evicted); cache keys are `sha256(token)`; an inactive answer evicts the entry. Concurrent introspects of the same token share one in-flight request.
  - `reserve` returns `{ ok: true, reservationId, expiresAt }` or `{ ok: false, code, message }` or throws `AuthServiceError`. `request_id` is generated by the caller and passed through.
  - `settle` and `release` never throw to the caller: on failure they append a record to a durable outbox under `<stateDir>/auth-outbox/` (one JSON file per record, mode 0600, atomic write) and `flushOutbox()` retries them with exponential backoff (30 s, then doubling, capped at 15 minutes), at startup and on a timer that does not keep the process alive. Records older than 72 hours are dropped with a log line; at most 1000 records are kept (oldest dropped with a log line).
  - Responses are read with a hard cap of 64 KB and parsed strictly (a field of the wrong type is a `bad-response`); redirects are refused; the bearer token and service token are never written to logs or errors (errors from the service are redacted and truncated to 200 characters).
- Add `examples/external-auth-stub.js`: a runnable reference implementation using only Node built-ins, with in-memory accounts, keys, balances and reservations, implementing the four calls per the document, configurable by environment variables (a list of `key:principal:credits` entries, a failure-injection switch for tests), listening on loopback. It is an example and test fixture, not production code, and says so at the top.
- Add `tests/mcp-extauth.sh` (this phase's part): run the stub, then exercise the client directly with a small Node script: valid and invalid tokens; cache hit within the TTL and re-validation after it (using an injectable clock); revocation visible after the TTL; concurrent introspects share one request; reserve success and each refusal code; idempotent `request_id`; timeouts, 5xx, malformed, oversized and redirecting responses all become `AuthServiceError`; settle and release failures land in the outbox with mode 0600 and are delivered later by `flushOutbox()` exactly once; `validateConfig` rejections; and a test that neither token ever appears in captured log output.

### Acceptance Criteria

- `bash tests/mcp-extauth.sh` passes.
- The protocol document defines every field, every status code, idempotency, and failure behavior without referring to any specific platform.
- No file other than the listed ones is modified, and no new dependency is added.
- Outbox files are created with mode 0600 and contain no bearer token or service token.

## Phase 2 - Integration into the Hosted Server

<!-- runner:model=codex:gpt-5.4 -->
<!-- pilot:touches=lib/mcp/http.js -->
<!-- pilot:touches=bin/e3d-mcp -->
<!-- pilot:touches=lib/mcp/metering.js -->
<!-- pilot:touches=tests/mcp-extauth.sh -->
<!-- runner:verify=bash tests/mcp-extauth.sh && bash tests/mcp-http.sh && bash tests/mcp-usage.sh -->

### Requirements

- When `E3D_MCP_AUTH_URL` is set (hosted `--http` mode only): `bin/e3d-mcp` validates the configuration at startup and refuses to start on any `validateConfig` error. `E3D_MCP_AUTH_TOKENS` is ignored in this mode and the server logs one warning line saying so. Setting `E3D_MCP_AUTH_URL` without `--http` is an error.
- In `lib/mcp/http.js`, authentication becomes asynchronous. With the hook configured, every `/mcp` request (not only `initialize`) calls `introspect` through the cache:
  - inactive, or an `AuthServiceError`: respond 401 for inactive (`www-authenticate: Bearer realm="e3d-mcp"`), 503 with `retry-after: 5` for service failures; no model is ever called in either case;
  - active: the principal comes from the service; the connection's tool allowlist is the intersection of the operator's `E3D_MCP_HTTP_TOOLS` allowlist and the service's `tools` (when present), never wider than the operator's; `rate_per_min` and `max_inflight` from the service may lower, never raise, the server's own limits;
  - a session is bound to the principal it was created with: a different principal on the same session id is the existing "unknown session" response;
  - a token that becomes inactive stops working on the next request after the cache expires, and existing sessions for that principal are dropped.
- Add `lib/mcp/metering.js` exporting `createMetering({ localUsage, external, log })` with `reserve(principal, cost, kind, meta)`, `settle(handle, actual, meta)` and `release(handle, reason)`. It composes the two layers so a request must pass both:
  - order: external `reserve` first, then local `reserve`; if the external reservation is refused, return the refusal (with the service's code and message) and touch nothing locally; if the local reservation is refused, release the external one before returning;
  - `settle` settles local and external to the actual use; external `settle` failures go to the outbox and never fail the user's request;
  - `release` releases both; failures are queued;
  - with no external service configured, `createMetering` returns an object that delegates to `localUsage` unchanged.
- `toolDebate` in `bin/e3d-mcp` uses the metering object. A refusal from the service returns an MCP tool error starting `error: billing:` followed by the service's message (truncated to 200 characters), and the existing local refusal text is unchanged. The result's `budget` field keeps its current shape (local view) and gains `billing: { principal, reservation_id }` only when the hook is active.
- The usage state file and rate limits use the service-provided principal id (already validated), so two different keys of one account share one budget and one rate window.
- Add `/readyz` (hook mode only; 404 otherwise): returns 200 `{ "status": "ok" }` if an `introspect` of a sentinel token has recently (within 60 seconds) received a well-formed response from the service, otherwise 503; it never reveals the URL or any credential.
- Extend `tests/mcp-extauth.sh`: start the stub and the real server in `--http` mode against it, with the debate binary stubbed as the existing HTTP tests do, and verify: valid key can initialize and run a debate; invalid key gets 401 and the stub saw no reserve; stub down gets 503 and no debate binary run; reserve refused (`insufficient_credits`) returns the billing error and runs nothing; the stub's reservation is settled to actual use (calls equal what the stub debate used) and a refused local cap releases the external reservation; revoked key stops working after the cache TTL (short TTL in the test) and its session is dropped; tools are narrowed by the service; two keys for one principal share a budget; a service-lowered rate limit is honored; `/readyz`; and that without `E3D_MCP_AUTH_URL` behavior is identical to before (run the existing static-token checks).

### Acceptance Criteria

- The three verify scripts pass, and every pre-existing MCP test still passes without edits.
- With the hook active, no code path calls a model before both reservations succeed.
- A stub outage can never produce a free debate; this is covered by a test.
- Neither the caller's token nor the service token appears in server logs, tool results, or state files (test greps for planted marker values).

## Phase 3 - Hardening, Documentation, and Operations

<!-- runner:model=codex:gpt-5.4 -->
<!-- pilot:touches=lib/mcp/external-auth.js -->
<!-- pilot:touches=lib/mcp/metering.js -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=docs/external-auth.md -->
<!-- pilot:touches=tests/mcp-extauth.sh -->
<!-- pilot:touches=tests/mcp-usage.sh -->
<!-- runner:verify=bash tests/mcp-extauth.sh && bash tests/mcp.sh && bash tests/mcp-usage.sh && bash tests/mcp-http.sh -->

### Requirements

- Failure and abuse tests in `tests/mcp-extauth.sh`: a service that returns slowly (timeout honored, request refused, server stays responsive); a service that returns very large or never-ending bodies (cap honored); a service that redirects; a service that returns an inactive answer for a token that was just active (evicted); introspect storms (many concurrent requests with different tokens do not overrun the in-flight limit or memory: cache size cap holds); settle outage (many debates complete, outbox fills up to its cap, oldest dropped, remaining delivered exactly once after recovery, no duplicates thanks to idempotent `reservation_id`); a server restart with a non-empty outbox delivers it at startup; two server processes sharing one state directory do not deliver the same record twice.
- Reservation expiry: if a debate runs longer than the reservation's `expires_at`, the server still settles it, and the document states that the service must accept a settle after expiry and apply the actual cost. Add a test with a short expiry.
- Observability without leaks: `e3d_usage` (hook mode) additionally reports `billing: { principal }` and whether the outbox has pending records (count only). A `--doctor` check reports the hook configuration (URL host only, token present or not, cache TTL) and whether the service answers a health call, never the credentials.
- README: add a "Hosting with an external auth and metering service" section: when to use it, the environment variables (`E3D_MCP_AUTH_URL`, `E3D_MCP_AUTH_SERVICE_TOKEN`, `E3D_MCP_AUTH_SERVICE_TOKEN_FILE`, `E3D_MCP_AUTH_CACHE_SEC`), the fail-closed behavior, how local caps remain as a second ceiling, how to run the reference stub, and a link to `docs/external-auth.md`. State plainly that the hook only checks identity and spend; it does not make the code-writing tools safe to expose.
- `docs/external-auth.md`: add a security checklist for implementers (store only key hashes, constant-time comparison, rate-limit `introspect`, make `reserve` atomic against the balance, idempotency semantics, expiry sweeps, audit logging without secrets) and a compatibility section (protocol version header; unknown response fields are ignored; unknown request fields from a future version must be ignored by the service).
- Remove nothing and change no defaults: static-token hosted mode and stdio mode keep their documented behavior.

### Acceptance Criteria

- The four verify scripts pass.
- The outbox never delivers a record twice, never holds more than its cap, and survives a restart.
- `--doctor` and `e3d_usage` expose no credential or full URL path.
- The protocol document and the stub agree: a test runs a request through the stub for every documented call and response, including each refusal code, and fails if the document lists a code the stub does not implement.

## After This Ticket (not in scope here)

- The platform side: a pilot product, credit packs, per-account keys and the reserve/settle service on the e3d.ai platform (separate epic, private repository).
- Usage events to an analytics store, dashboards and alerts.
- A hosted account-deletion flow that revokes keys and cancels subscriptions.
- A sandbox design that would allow code-writing tools for customers.

**Jev pre-screen (shadow mode, informational only):** obviousness noul=0.26 (1.0 = clearly obvious, 0.0 = clearly needs debate) -- logged for calibration, does not affect whether this debate runs.

## Round 1 -- codex

## Must-fix

1. **Phase 1/3 — outbox “exactly once” is impossible as specified.** A crash after the service commits but before the file is deleted necessarily causes redelivery. Two processes can also read and send the same file.  
   **Fix:** promise *at-least-once delivery with exactly-once ledger effect*. Require atomic file claiming (`rename` into process-owned/inflight state), stale-claim recovery, and backend idempotency. Tests must distinguish HTTP attempts from one effective settlement.

2. **Phase 1/3 — dropping outbox records gives free usage.** Discarding the oldest record at 1,000 or after 72 hours permanently loses charges. This contradicts fail-closed billing.  
   **Fix:** never silently discard unsettled usage. When storage reaches a bound or records exceed an operational deadline, reject new billed work and expose unhealthy status until delivery or explicit operator reconciliation.

3. **Phase 1 protocol — settle/release race is undefined.** A queued release can arrive after settle, or vice versa. “Unknown/already settled returns success” can silently erase a legitimate charge.  
   **Fix:** define one reservation state machine and precedence: settlement is terminal and billable; release succeeds only from reserved; conflicting terminal operations return a stable result. Idempotency must cover payload mismatch detection.

4. **Phase 2 metering — rollback covers refusal but not exceptions/crashes.** If external reserve succeeds and local reserve throws, the external hold is leaked. A lost reserve response can also leave an unreachable reservation.  
   **Fix:** release on every local non-success, including exceptions; retry `reserve` with the same `request_id`; require repeated reserves to return the identical reservation. Persist the external handle before local reservation if crash recovery is required.

5. **Phase 2 — “failures release” can provide free model usage.** The existing `toolDebate` releases whenever settlement is not reached, even if some model calls already occurred.  
   **Fix:** settle measurable partial usage after any model call; release only when actual calls are zero. Add timeout, malformed transcript, synthesis failure, and process-error tests.

6. **Phase 2 — local principal filenames collide.** Existing `usage.js` maps unsupported characters to `_`; permitted principals `a:b` and `a_b` therefore share budgets.  
   **Fix:** hash or reversibly encode principal filenames. Add `lib/mcp/usage.js` to Phase 2 touches and test collisions.

7. **Phase 2 — revocation/session behavior is unimplementable or over-broad.** An inactive response contains no principal, yet the server must drop sessions “for that principal.” Dropping all principal sessions would also terminate sessions belonging to another still-valid key.  
   **Fix:** bind sessions to both token digest and principal; revoke sessions for that credential. Specify whether principal-wide revocation is a separate signal.

8. **Phase 2 — refreshed authorization is not applied to existing sessions.** Current connections capture the tool allowlist at initialization. Re-introspection alone will not enforce later tool narrowing or changed limits.  
   **Fix:** recompute effective authorization on every request and enforce it at dispatch. Define `max_inflight` as per-principal and test mid-session narrowing.

9. **Phase 3 scope is internally impossible.** It requires `--doctor` and `e3d_usage` changes but does not permit touching `lib/mcp/doctor.js`, `bin/e3d-mcp`, or `lib/mcp/usage.js`.  
   **Fix:** expand the phase touch list and add direct acceptance tests.

10. **Shared Constraints/Phase 1 protocol are contradictory or incomplete.** “Strict” responses conflict with Phase 3’s “unknown fields ignored.” Request cap, numeric ranges, ID lengths, timestamp rules, URL path joining, token-file precedence/newline/symlink handling, and sensitive `message` treatment are unspecified. `/doctor` references an undefined health call.  
    **Fix:** define these wire rules explicitly and add conformance vectors.

11. **Reservation expiry is financially unsafe.** Requiring settlement after expiry does not say whether funds remain held or may be spent elsewhere.  
    **Fix:** require sufficient validity before starting, renewal, or a backend guarantee that expiry does not remove settlement liability.

## Nice-to-have

- Make `/readyz` use a documented health operation instead of a magic sentinel token.
- Test crash points around outbox claim/send/ack, not merely graceful restarts.
- Require mode `0600` for existing usage files too; currently they are written without an explicit mode.

**Recommendation: fix first.** The current design can lose settlements, provide free partial usage, collide customer budgets, and cannot satisfy its advertised outbox guarantee.

## Round 1 -- claude

**Recommendation: fix first.** The design is sound, but several defects would let an implementer ship double-charges, free usage, or a protocol nobody else can implement. I'm working from the spec text alone and haven't read the repo code.

## Must-fix

1. **Outbox exactly-once with two processes (Phase 1 outbox, Phase 3).** The spec says "one file per record, atomic write", but it defines no claim or lock protocol. Two processes calling `flushOutbox()` will both read the same record and both send it.
   - Idempotency makes duplicates harmless for correctness. That conflicts with the acceptance criterion "never delivers twice", which can't be guaranteed.
   - Fix: restate the guarantee as at-least-once delivery with an idempotent service, and have the tests assert end state (settled once) rather than send count.
   - Add a claim step (`rename` to `.claim.<pid>`, or `O_EXCL` lock) with stale-claim recovery.
   - Specify the backoff state (`next_attempt_at`, `attempts`) inside the record, so it survives a restart.
   - Specify that a record is deleted only after a confirmed `ok:true`.

2. **Settle and release race on one reservation (Phase 2 metering).** Nothing says a reservation can only be settled or released, never both.
   - Example: release is queued after a timeout while settle later succeeds. Or a settle is queued, and then a release is sent for the same ID.
   - Fix: specify a terminal-state rule. The service's first terminal call wins, and later conflicting calls return `ok:true` unchanged. The server must never enqueue both for one handle.

3. **Reserve timeout leaks a reservation (Phase 2).** If `reserve` times out, the service may have created it, and the server then refuses the request.
   - Customer credit stays locked until expiry.
   - Fix: on reserve timeout or failure, enqueue a `release` keyed by `request_id`. This means the protocol must allow `release` by `request_id`, because the server has no `reservation_id` yet.

4. **Local reserve and settle semantics under a principal change (Phase 2).**
   - Local usage is keyed by the service principal, but the cached principal can change between reserve and settle. Fix: capture the principal in the handle and use only that.
   - The spec doesn't say whether the local reserve uses the same units as the external one. Fix: state that both use the same `worstCase`.
   - Local settle failure must not skip external settle. Fix: settle externally first, or run both in `finally`.
   - Process crash between external and local reserve leaves an orphan external reservation until expiry. Fix: accept this and document it, and require the service to expire reservations.

5. **Revocation timing and session binding (Phase 2).**
   - "Dropped on the next request after cache expiry" means an in-flight debate and an idle session stay live up to the TTL (maximum 300 s) plus the debate duration.
   - Fix: state the maximum revocation latency explicitly. Allow the service to return a short `expires_at`. Optionally add a `/revoke` push.
   - The session is bound to the principal, but two keys on one principal share a session. Revoking one key doesn't drop sessions made with the other. Fix: bind the session to the `sha256(token)` and the principal. Then a revoked key's sessions die and sibling keys' sessions survive, or document that choice.
   - "Existing sessions for that principal are dropped" is wrong in the multi-key case, because it kills a sibling key's sessions.

6. **Principal id collision (Phase 2).** Principal ids from the service are used in state file names. Check that `.` and `..` can't pass, since the regex allows `..`. Fix: reject ids made only of dots, and use a safe encoded filename.
   - Also, a service principal could collide with an existing static-token name. In hook mode static tokens are ignored, but stale state files exist. Fix: namespace the state files as `ext-<principal>`.

7. **`/readyz` sentinel (Phase 2).** Introspecting a sentinel token on every readiness probe lets anyone hit the billing service unauthenticated.
   - Fix: serve readiness from the last real response, or probe at a rate limit. Also define the sentinel value, which the spec doesn't.

8. **Unauthenticated and DoS paths (Phase 2).** An introspect on every `/mcp` request, including invalid tokens, is amplification against the billing service. The 5 s negative cache helps, but a storm of unique random tokens bypasses it.
   - Fix: add a global in-flight introspect cap (the spec mentions it only in the Phase 3 test), a per-IP limit, and a max token length before hashing.

9. **Phase independence.** Phase 1's verify only tests the client against the stub. Phase 2 and Phase 3 both edit `tests/mcp-extauth.sh` and `external-auth.js`.
   - The Phase 3 acceptance criteria require "outbox never holds more than cap, survives restart", but these are Phase 1 requirements, so the Phase 1 tests are insufficient.
   - Fix: move the outbox concurrency, restart and cap tests into Phase 1. Make Phase 3 only hardening of what's already tested.
   - Also fix the doc/stub agreement test, which is in Phase 3 but tests Phase 1 artifacts.

10. **Test weaknesses that pass while behavior is wrong.**
    - "Settled to actual use (calls equal)" doesn't check tokens or models.
    - There's no test for double-settle or release-after-settle.
    - There's no test that the debate binary was never executed on a refused reserve. Fix: have the stub binary write a marker file, and assert the file is absent.
    - The planted-token grep must cover the outbox directory.
    - There's no crash-between-reserves test.

## Should-fix

- **Third-party implementability.** The doc lacks the full error-code table, which `message` fields are sensitive, the expected `Content-Type` of responses, the clock-skew rule for `expires_at`, the unit definitions (`est_tokens` basis), and a `kind` enum for future use. Add JSON schemas or examples.
- **Config.**
  - Specify that a bad `E3D_MCP_AUTH_CACHE_SEC` fails startup rather than being clamped silently.
  - Service token rotation needs a re-read of the file, or a documented restart.
  - "Loopback" should be checked on the parsed hostname, and a hostname like `localhost.evil.com` must not match.
- **Protocol versioning.** `X-E3D-Auth-Version: 1` has no defined behavior when the service rejects the version.
- **`introspect` request body.** It carries the raw token in a POST body. Say that explicitly and require HTTPS (already required).
- **Rate limits.** "May lower, never raise" is fine, but the cache means a limit change takes TTL seconds to apply. Document that.

## Scope

Overall the scope is about right, but Phase 2 is the largest. Consider splitting `/readyz` and the metering module into their own sub-steps. Phase 3 is mostly tests plus docs, which is fine.

## Round 2 -- codex

My prior position holds. Claude reaches the same “fix first” recommendation and usefully adds persistent backoff metadata, token-length limits, reserve-timeout handling, and stronger test assertions. Two proposed fixes need adjustment.

## Must-fix

1. **Phase 1/3 — outbox guarantee is impossible.** Atomic files alone cannot prevent two processes or crash-after-commit redelivery.  
   **Fix:** promise at-least-once transport with exactly-once ledger effect; specify atomic claiming, stale-claim recovery, persistent retry metadata, deletion only after `ok:true`, and payload-mismatch detection.

2. **Phase 1/3 — bounded outbox contradicts fail-closed billing.** Dropping records after 72 hours or beyond 1,000 gives away completed usage.  
   **Fix:** retain/reconcile records and stop accepting new billed work when the safety bound is reached. Readiness must become unhealthy.

3. **Phase 1 protocol — settle/release ordering remains unsafe.** Claude’s “first terminal call wins” permits a queued release to erase liability for usage that actually occurred.  
   **Fix:** release only when actual calls are zero; settlement with usage must take precedence. Define the backend state machine, conflict results, and idempotent payload matching.

4. **Phase 1/2 — ambiguous reserve timeouts leak holds.** Claude correctly identifies this, but “release by request_id” is an unnecessary second identity unless fully specified.  
   **Fix:** retry `reserve` using the same `request_id` to recover the identical reservation ID, then release it. Define expiry as the final recovery mechanism.

5. **Phase 2 — composition is not crash-safe.** External reserve followed by local reserve has an unavoidable crash window; local and external settlement also cannot be made atomic merely by choosing an order.  
   **Fix:** persist a metering transaction/intent before model execution, recover it after restart, release on every local non-success, and independently attempt both settlements.

6. **Phase 2 — partial failures could produce free usage.** “Failures release” is wrong after any model call.  
   **Fix:** derive and settle partial actuals for timeout, malformed transcript, synthesis failure, and child-process error; release only at zero calls.

7. **Phase 2 — principal/session/state identity is underspecified.** Bind sessions only to principal and revoking one key can kill sibling-key sessions or leave the revoked key’s session usable. Existing filename normalization may also collide principals.  
   **Fix:** bind sessions to token digest plus principal; hash/encode and namespace local usage keys; enforce refreshed tools and limits on every request.

8. **Phase 2/3 — abuse controls and expiry are incomplete.** Unique-token storms bypass the negative cache, and reservation expiry does not preserve charge liability.  
   **Fix:** bound token length and global introspect concurrency; specify revocation latency; require renewal or durable post-expiry settlement liability.

9. **Phase 3 — allowed files contradict required work.** `--doctor` and `e3d_usage` require files absent from `pilot:touches`.  
   **Fix:** expand the touch list and add direct verification.

10. **All phases — protocol and phase verification are incomplete.** Strict parsing conflicts with ignoring unknown fields; numeric bounds, timestamp skew, URL joining, sensitive messages, health semantics, and request caps are undefined. Core restart/concurrency tests arrive two phases after the outbox implementation.  
    **Fix:** publish schemas/conformance vectors and move correctness tests into the phase that introduces each guarantee.

## Nice-to-have

- Replace sentinel introspection with a documented, rate-limited health operation.
- Test every crash boundary and assert ledger effects, not HTTP attempt counts.
- Grep all state/outbox paths for planted secrets.

POSITION: Fix first because the current spec can lose charges, erase liability through release races, mishandle revocation, and cannot meet its outbox guarantees.
status: approved

## Round 2 -- claude

**Recommendation: fix first.** After reading codex's round-1 list, I'm keeping my position and adopting several of its points. I'm still working from the spec text alone and haven't read the repo.

## What I'm adopting from codex

1. **Outbox must not drop records (codex #2).** I missed this, and it matters. The spec drops the oldest record at 1000 entries or after 72 hours. Each dropped record is a debate that was run and never billed, which is free usage. I'm changing my position. Never silently discard unsettled usage. At the cap, refuse new billed work (fail closed) and report unhealthy status. Keep age-out only as an operator-visible reconciliation action.

2. **Partial usage after failure (codex #5).** "Failures release" is wrong once any model call has happened. Settle the measurable usage and release only when actual calls are zero. This is a stronger version of my reserve/settle/release point.

3. **Principal filename collision (codex #6).** Codex is right that `a:b` and `a_b` can map to the same file if usage.js sanitizes with `_`. I only flagged `..` and namespacing. The fix is to hash or reversibly encode the filename. This also means Phase 2 must touch `lib/mcp/usage.js`.

4. **Phase 3 touch list is impossible (codex #9).** `--doctor` and `e3d_usage` live in files Phase 3 doesn't list. Add them to the touch list.

5. **Per-request authorization (codex #8).** The tool allowlist is captured at `initialize`, so re-introspecting alone won't enforce narrowing later. Recompute the effective allowlist and limits on every request.

6. **Reservation expiry (codex #11).** A settle after expiry doesn't say whether the funds stayed held. Require the backend to keep settlement liability after expiry, or require enough validity before starting.

7. **Strict vs. ignore-unknown-fields (codex #10).** The contradiction is real. Define that unknown fields are ignored and wrong types are rejected.

## Where I hold my position

- **Exactly-once.** Codex and I agree the guarantee should be at-least-once delivery with an idempotent effect, plus an atomic claim by `rename` and stale-claim recovery. Tests should assert the end state, not the send count.
- **Reserve-timeout leak.** Codex says to retry `reserve` with the same `request_id`. I think that is necessary but not enough. If the retry also fails, the server must enqueue a `release` keyed by `request_id`, so the protocol needs release-by-`request_id`. Both are needed.
- **Session binding.** Codex says to bind sessions to the token digest and principal. I agree. This also resolves my multi-key concern: revoking one key kills only that key's sessions. An inactive response has no principal, so the server must look sessions up by token digest.
- **`/readyz` and introspect amplification.** Codex lists `/readyz` only as a nice-to-have. I think it's a real hole, because an unauthenticated probe hits the billing service. I also raised the introspect storm: unique random tokens bypass the negative cache. This needs a global in-flight cap, a per-IP limit, and a token length cap.
- **Phase independence.** Codex doesn't address this. The outbox restart, concurrency and cap tests are Phase 1 behavior but are verified only in Phase 3. Move them to Phase 1.
- **Settle/release state machine.** Codex and I agree on a terminal-state rule. Codex adds payload-mismatch detection for idempotency keys, which I'll adopt. Its "settlement is terminal and billable" precedence is clearer than my "first terminal call wins," because a release must never override a settle.

## Must-fix, merged

1. Outbox: at-least-once with an idempotent effect, atomic claim, no silent drops, backpressure at the cap, backoff state in the record.
2. Reservation state machine, with settle taking precedence, payload-mismatch detection, and release by `request_id`.
3. Release on every local failure including exceptions, and settle partial usage once any model call has run.
4. The principal captured in the handle, hashed filenames, and the same `worstCase` units for both layers.
5. Sessions bound to token digest and principal. Authorization recomputed per request. State the maximum revocation latency.
6. Introspect DoS limits and a `/readyz` that doesn't proxy unauthenticated probes.
7. Phase touch lists fixed, outbox tests moved to Phase 1, and a stub binary marker file so tests prove no model ran.
8. Wire-rule gaps (sizes, ranges, timestamps, token file handling) filled in, with conformance vectors.

POSITION: Fix first. I agree with codex's core must-fixes and add reserve-timeout release by request_id, introspect and /readyz DoS limits, moving the outbox tests into Phase 1, and the `.`/`..` principal case.
status: approved


## Synthesis (fast path, no LLM call)

FINAL ANSWER: Fix first because the current spec can lose charges, erase liability through release races, mishandle revocation, and cannot meet its outbox guarantees.
CONSENSUS: full
DISSENT: none
