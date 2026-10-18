# Hosted debate runs: async tools, a run store, and the debate contract (finalize, fetch, authorize-run)

## Overview

A debate takes minutes. Over the hosted HTTP transport the synchronous `e3d_debate` tool is one long request with no progress, so
a client that gives up early (Claude Code stops waiting at about 60 seconds; chat clients are often stricter) drops the answer
while the server finishes the debate and settles the charge: the customer pays and never sees the result (verified locally on
2026-10-18 with a 90 second debate). This ticket makes debates durable, retrievable runs: connectors can start a debate and
fetch it later, a finished debate is settled and stored by the billing service in ONE atomic operation (`finalize`), and the
hosted server can execute a debate that the billing service has already reserved (used by the web "Ask" page). Everything is
off unless the external auth hook is configured and the service advertises the new calls; the synchronous `e3d_debate`, stdio
and static-token modes keep working unchanged. A companion spec in `e3d-pilot-cloud` (`docs/pilot-debates-spec.md`) implements
the service side; the **Debate contract v1** below is normative for both, and both repositories carry the same schemas and
conformance fixtures, pinned by the contract version and a SHA-256 recorded next to them.

## Decisions

- **D1. Customer tools** (hook and HTTP mode only; added to the customer allowlist **only when the service advertises
  `finalize`**, so a customer can never run a paid async debate that cannot be stored): `e3d_debate_start` (same arguments as
  `e3d_debate`; returns `{debate_id, status:"running", poll_after_sec}` once the reservation is held and a run slot is taken),
  `e3d_debate_status {debate_id}`, `e3d_debate_result {debate_id, include_transcript}`. The synchronous `e3d_debate` stays; when
  `finalize` is advertised it also finalizes (settles and stores in one call) instead of settling alone.
- **D2. Three different ids, never conflated.** `request_id` (UUID; the metering and idempotency key of one reserve, as today),
  `reservation_id` (`rsv_...`, assigned by the service), and `debate_id` (`dbt_` + 24 lowercase hex, assigned by whoever
  creates the run: the MCP server for connector runs, the billing service for web runs). The service stores the mapping and
  enforces uniqueness of `debate_id` and of `reservation_id`; the binding `{reservation_id, debate_id}` is immutable. A
  principal reads only its own debates; an unknown id and someone else's id answer identically (`not_found`).
- **D3. Never charge without a durable result.** The server sends exactly one `finalize` per reservation. The charge rule lives in
  the service (`outcome:"ok"` with a result present charges the price; error and timeout charge the service's failed price,
  default 0; zero model calls releases). The server never settles a debate by any other path when `finalize` is advertised. An
  interrupted run (server restart or crash) is finalized with `outcome:"error"` and no result on restart, so it is never charged
  beyond the failed price; the orphan policy applies only when `finalize` is not advertised. A durable "models started"
  transition is written to the run's `state.json` before any model is invoked; queued runs that never started are resumed or
  released on restart deterministically (released if older than the run timeout).
- **D4. Run store.** Per-run state in `runs/<sha256(principal) first 32 hex>/<debate_id>/` (`state.json`, `transcript.md`), written
  atomically (temp file, fsync, rename), mode 0600 in 0700 directories, with a TTL (default 24 hours: the service holds the
  durable copy), a per-principal cap (default 50; oldest finished first), and a total byte cap for the run store and for pending
  `finalize` outbox items (default 64 MB each; at the bound new starts are refused before reserving, never silently dropping a
  pending finalize). Question and answer text never appear in logs, stats or listings.
- **D5. Admission and limits.** A run slot is acquired atomically BEFORE the reserve (`E3D_MCP_RUNS_PER_PRINCIPAL` default 3,
  `E3D_MCP_RUNS_GLOBAL` default 8, queued runs count); a refused slot returns the `busy` tool error and reserves nothing; a slot is
  released on every exit path. In `per_debate` pricing the cost drivers are fixed for customers: rounds at most 2, words per answer
  at most 300, at most 3 providers (`E3D_MCP_CUSTOMER_LIMITS`), whatever the caller passes. Question length at most 8000
  characters, no control characters. `status` and `result` are rate limited per principal.
- **D6. `finalize` (hook call, optional, durable).** Delivered through the outbox as a new record type (idempotent per
  `reservation_id`; this replaces `settle` for debates, it is not sent in addition). Body: Debate contract v1 below, at most
  512 KB in total; the transcript is truncated at a section boundary to fit and `truncated:true` is set. Answers: `ok` (with
  `stored`), `conflict` (same reservation, different canonical body), `not_found` (unknown reservation), `invalid`, `too_large`
  (permanent: dead-lettered), `unavailable` and `not_ready` (retryable). A debate deleted or an account closed while running
  still settles with `stored:false`.
- **D7. `fetch {debate_id, principal}` (optional).** Used by `status` and `result` when the run is not in the local store and the
  service advertises it. `principal` is only a claimant, compared by the service with the owner it derives through the
  reservation; non-owner and unknown answer identically. A negative cache (60 seconds) and the per-principal rate limit stop it
  being used as an oracle.
- **D8. `authorize-run {reservation_id, debate_id}` (optional, used by the internal run listener).** Returns the owner principal,
  the price held, and the binding status; the listener derives ownership only from this answer, never from the request body, and
  refuses before any model work if the service refuses. The same pair again returns the same answer; the same `debate_id` with
  a different reservation, or the reverse, is `conflict`.
- **D9. Capability advertisement.** `introspect` answers may carry `features` containing any of `finalize`, `fetch`, `authorize-run`
  (no other values); the server uses only what is listed. No `features` means today's behaviour exactly.
- **D10. Internal run listener** (`E3D_MCP_RUN_PORT`, `E3D_MCP_RUN_TOKEN` of 32+ characters; 127.0.0.1 only, never reachable
  from the public listener): `POST /internal/runs {reservation_id, debate_id, question, providers?, rounds?, max_words?}`,
  `GET /internal/runs/{debate_id}` (status and progress; the result only to the caller that started it), `DELETE
  /internal/runs/{debate_id}` (cancel: the run finalizes with outcome `error` and no result, or the service has tombstoned it).
  A duplicate with identical fields returns the existing run; with different fields, `conflict`. A definitive rejection (`busy`,
  `invalid`, `conflict`, authorization refused) is distinguished in the response from "accepted".
- **D11. Docs and conformance.** `docs/external-auth.md` documents `features`, `finalize`, `fetch`, `authorize-run` and the run
  listener; the stub service and conformance runner implement and test all of them (including version-skew vectors: a server
  that knows `finalize` against a service that does not, and the reverse).

## Debate contract v1 (normative for both repositories)

JSON, snake_case on the wire. `finalize` request: `{reservation_id, debate_id, source:"connector"|"web", outcome:"ok"|"error"|
"timeout", actual:{calls,est_input_tokens,est_output_tokens}, models[], duration_ms, question, providers[], rounds, result:{
final_answer, consensus, dissent, positions:[{provider, model, position}]}|null, transcript:string|null, truncated:boolean,
started_at, finished_at}`; response `{ok:true, stored:boolean, charged:int}` or `{ok:false, code}`. `fetch` response
`{ok:true, debate:{debate_id, status:"queued"|"running"|"done"|"failed", outcome|null, question, providers, rounds, result|null,
usage, credits_charged, created_at, finished_at|null, truncated}}` (the transcript only when `include_transcript:true`) or
`{ok:false, code:"not_found"}`. `authorize-run` response `{ok:true, principal, price_credits, status:"reserved"|"bound"}`.
Statuses: 200 success, 400 `invalid`, 404 `not_found`, 409 `conflict`, 413 `too_large`, 429 `rate_limited`, 503 `unavailable`
or `not_ready` (retry with backoff). Timestamps are RFC 3339 UTC. Limits: question 8000 characters, whole `finalize` body 512 KB,
transcript at most 480 KB (the remainder is metadata). The schemas live in `docs/external-auth/` and are the single source.

## Goals

- A client with any timeout can run a debate (start, poll, fetch) and never loses a paid result; the customer is never charged
  without a stored result.
- The web page can run a pre-reserved debate on the same engine and limits as connectors.

## Non-Goals

- Storing transcripts beyond the short local TTL, any UI, OAuth, pricing, or retention policy (the billing service owns them).
- Changing stdio or static-token behaviour, the pipeline tools, or the synchronous tool's contract.

## Existing Files (read first)

- `bin/e3d-mcp`: `toolDebate`, the tool list and allowlists, `newHttpConn`, hook start-up, `--doctor`.
- `lib/mcp/http.js`, `metering.js`, `outbox.js`, `external-auth.js`, `usage.js`, `jobs.js` (ideas only), `redact.js`, `doctor.js`.
- `docs/external-auth.md`, `docs/external-auth/*`, `examples/external-auth-stub.js`, `examples/external-auth-conformance.js`.
- `tests/mcp-extauth.sh`, `tests/fixtures/extauth-*.mjs`, `tests/mcp-http.sh`: test style.

## Shared Constraints

- Zero new dependencies. Nothing logged contains a question, answer, transcript, key or token.
- Everything new is inert without the hook and an advertised capability; every existing mode, tool and test is unchanged.
- All new state is crash-safe (temp, fsync, rename; no partial JSON visible). Tool descriptions are plain language for
  non-developers ("start a debate", "check on a debate", "get the result").
- "Exactly once" is never claimed: the tested property is idempotent effect, with final balance and result presence asserted.

## Phase 1: The debate contract, client calls, outbox and conformance

Add the `finalize`, `fetch` and `authorize-run` calls to `lib/mcp/external-auth.js` (timeouts, redirect refusal, size caps, schema
validation, the `features` field from `introspect`), the `finalize` record type to `lib/mcp/outbox.js` (idempotent per
reservation, body cap and section-boundary truncation, dead-letter on permanent answers, retry on `unavailable` and `not_ready`,
total byte cap, mode 0600), the metering integration (when `finalize` is advertised the synchronous tool finalizes instead of
settling; a restart finalizes interrupted intents with outcome `error`), the schemas, stub service and conformance runner
(including the version-skew vectors), and the documentation.
<!-- runner:model=claude:opus -->
<!-- pilot:touches=lib/mcp/external-auth.js,lib/mcp/outbox.js,lib/mcp/metering.js,bin/e3d-mcp,examples/external-auth-stub.js,examples/external-auth-conformance.js,docs/external-auth.md,docs/external-auth/finalize.schema.json,docs/external-auth/fetch.schema.json,docs/external-auth/authorize-run.schema.json,docs/external-auth/CONTRACT-VERSION,tests/mcp-extauth.sh,tests/fixtures/extauth-finalize-test.mjs -->
Tests: a service without `features` is never sent the new calls and today's behaviour is unchanged (the whole existing suite
passes untouched); with `finalize` advertised, every synchronous debate (ok, error, timeout) results in exactly one stored
outcome and one balance change, idempotent across outage, restart, duplicate delivery and a process kill between the debate
ending and delivery; the truncation rule and the size caps; permanent answers dead-letter without affecting other records;
`not_ready` and `unavailable` retry; `fetch` returns the owner's debate and the identical `not_found` otherwise; version-skew
vectors both ways; schema, stub and runner agree (the conformance vectors reject malformed bodies); no content in logs, stats
or outbox listings (counts and ids only); the contract version file and fixtures hash match.

## Phase 2: The run store and the async tools

Add `lib/mcp/runs.js` (store, runner, admission slots before reserve, limits, TTL and caps, the durable "models started"
transition, interruption recovery, per-principal isolation, hashed directory names) and the three tools in `bin/e3d-mcp` using
the shared debate execution code (refactor `toolDebate`'s execution into a function without changing its behaviour), gated on
`finalize` being advertised, with the fixed customer cost drivers, per-principal rate limits and the `fetch` fallback with its
negative cache. Add the tools to the customer allowlist (only when gated in), `--doctor`, and the README.
<!-- runner:model=claude:opus -->
<!-- pilot:touches=lib/mcp/runs.js,bin/e3d-mcp,lib/mcp/http.js,lib/mcp/doctor.js,lib/mcp/external-auth.js,tests/mcp-runs.sh,tests/fixtures/runs-unit.mjs,README.md -->
Tests (stub debate binary and stub service): the tools are absent from `tools/list` unless `finalize` is advertised; start returns
well before the debate ends while it keeps running; status goes `running` to `done`; result returns verdict and positions, the
transcript only when asked; a second principal gets `not_found` for the first one's id (and a fetch fallback never leaks it);
a refused slot or reserve creates no run and reserves nothing; caps refuse before reserving and slots are released on every exit
path; fixed customer limits override caller arguments; TTL and cap eviction never remove a run whose finalize is pending;
restart finalizes interrupted runs with outcome `error` (balance unchanged beyond the failed price) and resumes or releases
queued runs; settlement and storage happen once when the client never polls; the synchronous tool is unchanged; byte caps
refuse new starts at the bound; no question or answer text in any captured log.

## Phase 3: The internal run listener

Add `lib/mcp/run-server.js`: the loopback-only listener, token check in constant time with a failure rate limit, strict body
validation, `authorize-run` before any model work, the metering handle built from the authorized reservation (no new reserve),
immutable binding and conflict handling, idempotent create, `GET` status and result, `DELETE` cancel, definitive-rejection
responses, and start-up, shutdown and `--doctor` wiring. It reuses the Phase 2 runner and the Phase 1 `finalize` path with
`source:"web"`.
<!-- runner:model=claude:opus -->
<!-- pilot:touches=lib/mcp/run-server.js,lib/mcp/runs.js,lib/mcp/metering.js,bin/e3d-mcp,lib/mcp/doctor.js,tests/mcp-runserver.sh,tests/fixtures/runserver-test.mjs,README.md -->
Tests: binds only to 127.0.0.1 and refuses to start with a short token; wrong or missing token is 401 with a failure rate limit;
ownership comes only from `authorize-run` (a body claiming another principal is ignored); a refused authorization starts no
model work; the same pair returns the same run, a different binding is `conflict`; an accepted run finalizes its reservation
once and never reserves again; cancel finalizes with outcome `error` and no result; limits and interruption behave as in
Phase 2; the public listener never serves these paths; bodies, questions and tokens never appear in logs.

## After This Ticket

- The service side lands in e3d-pilot-cloud (companion spec). Rollout order: contract and `finalize` first, then async tools
  (gated on the advertisement), then the web run path.
- OAuth for chat clients that cannot send a static key; push-style progress where a client supports it.
