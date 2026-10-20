# External auth and metering protocol (version 1)

When `E3D_MCP_AUTH_URL` is set, the hosted e3d-mcp server (`e3d-mcp --http`) delegates two questions to an
external service: **who is this caller** (`introspect`) and **may they spend** (`reserve`), and afterwards it reports
**what was actually used** (`settle`) or **gives back a hold that was never used** (`release`). This document is the
complete contract. Any billing backend can implement it; nothing in it is specific to one platform.

Machine-readable parts:

- JSON Schemas, one request and one response schema per call: [`docs/external-auth/`](external-auth/)
  (`<call>.request.schema.json`, `<call>.response.schema.json`). The optional [Debate contract v1](#debate-contract-v1)
  calls have one file each holding both (`finalize.schema.json`, `fetch.schema.json`, `authorize-run.schema.json`,
  under `$defs.request` and `$defs.response`), plus the shared fixtures `debate-fixtures.json`, all pinned by
  `CONTRACT-VERSION`.
- A reference implementation (example and test fixture, not production code): `examples/external-auth-stub.js`.
- Conformance vectors you can run against your implementation:
  `node examples/external-auth-conformance.js <base-url> <service-token>`.

## Transport

| | |
|---|---|
| Calls | `POST <E3D_MCP_AUTH_URL>/<call>` with a JSON body, for `introspect`, `reserve`, `settle`, `release` (and, only when advertised, `finalize`, `fetch`, `authorize-run`); `GET <E3D_MCP_AUTH_URL>/health` |
| URL joining | trailing slashes of the base are stripped, then `/<call>` is appended. A base with credentials, a query or a fragment is rejected at startup |
| Scheme | `https:` is required; `http:` only to loopback hosts. Certificate verification is never disabled. Redirects are never followed |
| Authentication | `Authorization: Bearer <service token>`; the token comes from `E3D_MCP_AUTH_SERVICE_TOKEN` or the file named by `E3D_MCP_AUTH_SERVICE_TOKEN_FILE` (which must not be group- or world-readable), at least 24 printable ASCII characters |
| Version | every request carries `X-E3D-Auth-Version: 1` |
| Limits | request body at most 16 KB, response body at most 64 KB (a `finalize` request at most 512 KB, a `fetch` response at most 2 MB) |
| Timeouts | 3000 ms for `introspect`, `reserve`, `health` and `authorize-run`; 10000 ms for `settle` and `release`; 15000 ms for `finalize`; 5000 ms for `fetch` |
| Types | numbers are non-negative safe integers within the bounds in the schemas; timestamps are RFC 3339 and compared with a clock-skew allowance of 60 seconds; principal ids match `^[A-Za-z0-9_.:-]{1,80}$`; `request_id` is a UUID |

## Calls

### `introspect`

Request `{ "token": "<the caller's bearer token>" }`.

Response, either:

- `{ "active": true, "principal": "<id>", "tools"?: ["e3d_debate", ...], "limits"?: { "rate_per_min"?, "max_inflight"? }, "expires_at"?: "<RFC 3339>", "features"?: ["finalize", "fetch", "authorize-run"] }`
- `{ "active": false }`

`features` advertises the optional [Debate contract v1](#debate-contract-v1) calls the service supports.

`tools` can only narrow the operator's `E3D_MCP_HTTP_TOOLS` allowlist, never widen it. `limits` can only lower the
server's own limits. `expires_at` caps how long the server caches the answer. Unknown, revoked and expired keys are
all simply `{ "active": false }`; the service must not say which.

### `reserve`

Request `{ "principal", "request_id": "<UUID>", "kind": "debate", "tool", "units": { "calls", "est_tokens" } }`.
`units` is the server's worst case for this debate.

Response, either:

- `{ "ok": true, "reservation_id", "expires_at" }`: funds for `units` are held until `expires_at`.
- `{ "ok": false, "code", "message" }`: a business refusal; `message` (at most 500 characters) is shown to the caller.

### `settle`

Request `{ "reservation_id", "actual": { "calls", "est_input_tokens", "est_output_tokens" }, "models": [ { "provider", "model", "calls" } ], "outcome": "ok" | "error" | "timeout" | "orphaned", "duration_ms" }`.

Response `{ "ok": true }` or `{ "ok": false, "code": "conflict", "message"? }`.

`outcome` is informational: usage is charged whatever the outcome. `orphaned` means the server crashed during the
debate and is settling on recovery.

### `release`

Request `{ "reservation_id", "reason" }` or `{ "request_id", "reason" }` (exactly one of the two ids; `reason` is a
short `snake_case` word such as `zero_usage`, `local_refused`, `ambiguous_reserve`). Response `{ "ok": true }`.

### `health`

`GET <url>/health` returns HTTP 200 `{ "status": "ok" }` when the service can serve requests. It takes no caller
token; the service may accept it without the service token, but a wrong service token must still be refused so
misconfiguration is visible. The service rate-limits it.

The answer may also carry `features` (the same array as `introspect`, see [Capability gating](#capability-gating)):
`{ "status": "ok", "features": ["finalize", "fetch", "authorize-run"] }`. It lets the server learn the advertisement without a
caller token (see below). It is optional and additive: a service that omits it behaves exactly as before.

## Refusal codes

<!-- conformance:codes -->
| Call | Code | Meaning |
|---|---|---|
| `reserve` | `insufficient_credits` | the balance minus current holds does not cover `units` |
| `reserve` | `suspended` | the account exists but may not spend |
| `reserve` | `limit_reached` | an account limit (for example concurrent reservations) is reached |
| `reserve` | `unknown_principal` | there is no such account |
| `reserve` | `conflict` | this `request_id` was already used with a different principal or different `units` |
| `settle` | `conflict` | already settled with a different payload, or the reservation is unknown |
<!-- /conformance:codes -->

## Error classes

| What the server sees | Class | What the server does |
|---|---|---|
| HTTP 200 with `ok: false` (or `active: false`) | business refusal | refuse the request with the service's message; nothing is retried |
| any other non-2xx status, a timeout, a connection failure, a redirect | service failure | fail closed: 503 to the caller, no model is called |
| a malformed, oversized or schema-invalid body | service failure | as above |
| HTTP 401 or 403 | configuration failure | as above, and logged distinctly: the service token or URL is wrong |

## Reservation state machine (normative)

A reservation has an id and one of these states: `held`, `settled`, `released`, `expired`.

- `reserve` creates `held` (or returns the existing reservation for the same `request_id`; a repeated `request_id`
  with *different* units is a conflict).
- `settle` with `actual.calls > 0` is **always accepted and charged**, whatever the current state: from `held`,
  `released` or `expired`. A release or an expiry never erases liability for usage that actually happened.
  `settle` with `actual.calls == 0` is equivalent to `release` (so it is `ok` on a settled reservation and changes
  nothing).
- A repeated `settle` with an identical payload returns `ok` and changes nothing; with a different payload it returns
  `conflict` and changes nothing. Payloads are compared on their known fields.
- `release` is only ever sent by the server when actual usage is zero. `release` of a `settled` reservation is a
  no-op returning `ok`. `release` may name the reservation by `reservation_id` or by `request_id` (for the case where
  the reserve response was lost).
- `expired` is the final backstop for holds nobody settled or released; the service releases the funds but must
  still accept and charge a later `settle` with usage.

Every transition, with the id the conformance vectors use:

<!-- conformance:transitions -->
| Id | From | Event | To | Response |
|---|---|---|---|---|
| `T-reserve-new` | (none) | `reserve`, new `request_id` | `held` | `ok`, new `reservation_id` |
| `T-reserve-repeat` | any | `reserve`, same `request_id` and same units | unchanged | `ok`, the same `reservation_id` |
| `T-reserve-conflict` | any | `reserve`, same `request_id`, different units | unchanged | `conflict` |
| `T-settle-held` | `held` | `settle`, `calls > 0` | `settled` | `ok`, charged |
| `T-settle-released` | `released` | `settle`, `calls > 0` | `settled` | `ok`, charged |
| `T-settle-expired` | `expired` | `settle`, `calls > 0` | `settled` | `ok`, charged |
| `T-settle-zero` | `held` | `settle`, `calls == 0` | `released` | `ok` (as `release`) |
| `T-settle-repeat-same` | `settled` | `settle`, identical payload | `settled` | `ok`, nothing changes |
| `T-settle-repeat-diff` | `settled` | `settle`, different payload | `settled` | `conflict`, nothing changes |
| `T-settle-unknown` | (none) | `settle`, unknown `reservation_id`, `calls > 0` | (none) | `conflict` |
| `T-release-held` | `held` | `release` by `reservation_id` | `released` | `ok` |
| `T-release-by-request` | `held` | `release` by `request_id` | `released` | `ok` |
| `T-release-settled` | `settled` | `release` | `settled` | `ok`, nothing changes |
| `T-release-released` | `released` or `expired` | `release` | unchanged | `ok` |
| `T-release-unknown` | (none) | `release`, unknown id | (none) | `ok`, nothing changes |
| `T-expire` | `held` | `expires_at` passes | `expired` | (funds released; settle liability kept) |
<!-- /conformance:transitions -->

## What the service must provide

- **Store only key hashes.** Customer keys are stored as hashes (for example SHA-256 of a high-entropy key), never in
  plaintext, and are shown to the customer once.
- **Constant-time comparison** of key hashes and of the service token.
- **Rate-limit `introspect`** (and `health`), so a flood of guessed tokens cannot enumerate keys or exhaust the service.
- **Atomic balance checks.** `reserve` checks the balance minus outstanding holds and creates the hold in one atomic
  step, so concurrent reservations cannot overspend.
- **Idempotency** exactly as in the state machine: per `request_id` for `reserve`, per `reservation_id` for `settle`
  and `release`. The server delivers `settle` and `release` at least once; idempotency turns that into exactly-once
  effect.
- **Expiry sweeps** that release held funds but keep the liability for a later `settle`.
- **No token logging.** Neither customer keys nor the service token appear in logs, errors or audit records.

## What the server guarantees

- **Fail closed.** If identity or budget cannot be established (refusal, timeout, error, malformed answer), the
  request is refused and no model is called.
- **Never free, never double.** No model runs before `reserve` returned a `reservation_id`. Usage that happened is
  settled, with at-least-once delivery (durable retry); `release` is sent only when actual usage is zero. A crash
  during a debate is settled on restart with outcome `orphaned`.
- **Bounded requests.** Every call has a timeout, a request and a response size cap; known fields are validated
  strictly and unknown fields are ignored.
- **Secrets stay secret.** The caller's token and the service token never appear in logs, errors, status output,
  tool results or state files. Caches and session tables are keyed by `sha256(token)`.
- **A second ceiling.** The server's local caps (`E3D_MCP_DAILY_CALLS`, `E3D_MCP_DAILY_EST_TOKENS`, rate limits)
  keep applying, so a fault in the billing service cannot make spend unbounded.

### Caching and revocation latency

`introspect` answers are cached in memory, keyed by `sha256(token)`: active answers for `E3D_MCP_AUTH_CACHE_SEC`
(default 30, from 1 to 300) or until `expires_at`, whichever is sooner; inactive answers for 5 seconds. At most 5000
entries are kept (oldest evicted). Concurrent introspects of one token share one request, and at most
`E3D_MCP_AUTH_MAX_INFLIGHT` (default 32) distinct introspects run at once; beyond that the server fails fast (503).

**Maximum revocation latency** = the cache TTL (`E3D_MCP_AUTH_CACHE_SEC`, at most 300 s) **plus the duration of a
request already in flight** when the key was revoked (that request completes and is settled).

## Compatibility

- Every request carries `X-E3D-Auth-Version: 1`. A service that does not support the version should answer 400.
  A future incompatible protocol will use a new version number.
- **Unknown fields are ignored** by both sides: a service may add fields to responses and the server may add fields
  to requests without breaking the other. Known fields are validated strictly; a wrong type or an out-of-range value
  is a failure.
- New refusal codes require a new protocol version (the server treats an unknown code as a malformed response, and
  fails closed).

## Debate contract v1

Optional calls for hosted debates: a finished debate is settled **and** stored by the service in one operation
(`finalize`), its owner can read it back later (`fetch`), and the server can run a debate the service reserved itself
(`authorize-run`, used by the internal run listener for web runs). This section is normative for e3d-pilot and for the
billing service; both carry the same schemas and fixtures, pinned by `docs/external-auth/CONTRACT-VERSION` (the line
`debate-contract 1`, then the SHA-256 of each pinned file in `sha256sum` format; `shasum -a 256 -c` checks it).

### Capability gating

`introspect` may answer `features`, an array of call names. Version 1 defines exactly `finalize`, `fetch` and
`authorize-run`; any other value is ignored by the server (a newer service never breaks an older server), and a missing
`features` means the original protocol exactly: the server sends none of these calls. The server uses only what is
advertised (the latest active `introspect` answer wins):

| Advertised | The server |
|---|---|
| nothing | settles debates with `settle`/`release`, exactly as before |
| `finalize` | finalizes every synchronous `e3d_debate` with `finalize` instead of `settle` (never both) |
| `finalize` and `fetch` | additionally offers the async debate tools (start, check on, and get the result of a debate) |
| all three | additionally enables the internal run listener for pre-reserved (web) runs |

The advertisement is also read from `GET /health`: when a `200 { "status": "ok" }` answer has a `features` array, the server
takes it as the current advertisement (same filtering as above; the latest answer wins, `introspect` or `health`). An answer
without a `features` key changes nothing. Nothing is learned from a failed, slow, malformed or non-200 answer. The server
probes `health` at startup and every `E3D_MCP_AUTH_HEALTH_SEC` seconds (15 by default; after a failure it retries after 1 s, 2 s,
4 s ... up to that interval), and, while the run listener sees the features unknown, at most once every 5 s when a web run
arrives. So after a restart, web runs become ready as soon as `health` answers, with no client call to `/mcp` needed.
A service that must serve web runs should therefore advertise `features` on `health` as well as on `introspect` (the two
must agree); one that does not still works, but its web runs stay `503 not_ready` after a server restart until some client
presents a valid key.

### Ids

`request_id` is the UUID reserve idempotency key; `reservation_id` is assigned by the service (for example `rsv_...`);
`debate_id` is `dbt_` followed by 24 lowercase hexadecimal characters, assigned by the server for connector runs or by the
service for web runs. The service keeps both `debate_id` and `reservation_id` unique and their binding immutable. A
principal reads only its own debates; unknown ids and ids owned by someone else answer identically (`not_found`).

### `finalize`

Request (all fields required):
`{ "reservation_id", "debate_id", "source": "connector" | "web", "outcome": "ok" | "error" | "timeout", "actual": { "calls", "est_input_tokens", "est_output_tokens" }, "models": [ { "provider", "model", "calls" } ], "duration_ms", "question", "providers": [...], "rounds", "result": { "final_answer", "consensus", "dissent", "positions": [ { "provider", "model", "position" } ] } | null, "transcript": "<markdown>" | null, "truncated", "started_at", "finished_at" }`.

An `ok` outcome carries a result; `error` and `timeout` carry `"result": null`. `question` is 1 to 8000 Unicode scalar
values without control characters other than tab, LF and CR. `actual`, `duration_ms` and `rounds` are non-negative integers.

Response `{ "ok": true, "stored": <boolean>, "charged": <credits> }` or `{ "ok": false, "code" }`; `stored: false` requires
`charged: 0`.

- **Never charge without a durable result.** For `ok`, the service charges the held price only if it atomically stores
  the result, answering `stored: true`. If it cannot or must not store it (the debate was deleted or the account closed
  while it ran), it answers `stored: false`, charges zero and releases the hold. `error` and `timeout` charge the
  service's configured failed price (default zero) and store the terminal record when permitted. Zero model calls always
  charge zero.
- **One immutable intent per reservation.** The server builds exactly one body per reservation and may deliver it many
  times. The effect is idempotent per `reservation_id`: the same canonical body again returns the original answer; a
  different body (or a `debate_id` already bound to another reservation) is `conflict`.
- **Limits.** The whole UTF-8 JSON body is at most 512 KB and the transcript at most 480 KB, so the metadata always has
  room. The server cuts only the transcript, at a section boundary (the longest prefix of whole sections, a section
  starting at a line that begins `## `), and sets `truncated: true`. A body that does not fit even without its transcript
  is never sent as a result: the server finalizes it as `error` without one. A question that cannot fit is refused before
  anything is reserved.
- **Delivery.** `finalize` goes through the durable outbox as its own record type (`finalize.reservation_id.<id>`).
  `unavailable`, `not_ready` (and rate limits or transport failures) are retried with bounded exponential backoff and
  jitter. `conflict`, `not_found`, `invalid` and `too_large` are terminal: the record is dead-lettered keeping ids, usage
  and the code only (the question, result and transcript are removed). The server never sends `settle` for a debate it
  finalizes.
- **Restart.** A debate whose models started but which has no recorded outcome (the process was killed) is finalized on
  restart as `outcome: "error"` with no result and the reserved units as usage; a recorded outcome is replayed as the
  identical body. The orphan policy (`E3D_MCP_ORPHAN_POLICY`) applies only when `finalize` is not advertised.

### `fetch`

Request `{ "debate_id", "principal", "include_transcript": <boolean> }`. `principal` is a claim: the service compares it
with the owner it derives through the reservation, and never treats it as proof of ownership.

Response `{ "ok": true, "debate": { "debate_id", "status": "queued" | "running" | "done" | "failed", "outcome": "ok" | "error" | "timeout" | null, "question", "providers", "rounds", "result": {...} | null, "usage", "credits_charged", "created_at", "finished_at": "<RFC 3339>" | null, "truncated", "transcript"? } }`
or `{ "ok": false, "code": "not_found" }` (identical for unknown and foreign debates). `transcript` is present only when
`include_transcript` is true. The server adds a 60 second negative cache and a per-principal rate limit.

### `authorize-run`

Request `{ "reservation_id", "debate_id" }`, sent only by the internal run listener. Response
`{ "ok": true, "principal", "price_credits", "status": "reserved" | "bound" }` or `{ "ok": false, "code" }`. The listener
takes the owner only from this answer, never from the run request, and refuses before any model work if it is not `ok`.
The same pair gets the same answer while the reservation is held; reusing either id with a different counterpart is
`conflict`. Once the reservation is finalized (or no longer held) every `authorize-run` for it is `conflict`, **even for the
same pair**, so a repeated run request for a finished debate can never start a second run.

### The internal run listener (web runs)

The service calls this listener, not the reverse. It is enabled by `E3D_MCP_RUN_PORT` and `E3D_MCP_RUN_TOKEN` (32+
characters), binds to `127.0.0.1` only, and accepts new runs only while all three features are advertised (otherwise
`503 not_ready`). Every request carries `Authorization: Bearer <E3D_MCP_RUN_TOKEN>`; failed authentication answers 401
and is rate-limited.

- `POST /internal/runs` `{reservation_id, debate_id, question, providers?, rounds?, max_words?}` (no other fields). The
  server calls `authorize-run` before any model work, meters the run from that reservation (never a new `reserve`), and
  finalizes it once with `source: "web"`. Answers carry `accepted`: `202` new run or `200` identical repeat, both
  `{ok:true, accepted:true, existing, debate_id, status, run_token}`; definitive refusals `400 invalid`,
  `403 not_authorized` (with the `authorize-run` code as `reason`), `409 conflict`, `429 busy`; `503 unavailable` or
  `not_ready` means nothing was accepted, so retry later. A refusal leaves the reservation with the service.
- `GET` and `DELETE /internal/runs/{debate_id}` also need `X-E3D-Run-Token: <run_token>`; an unknown id and a wrong run
  token both answer 401. GET returns `{ok:true, run:{debate_id, status, outcome, progress?, result?, usage,
  credits_charged, created_at, started_at, finished_at, cancelled?}}`. DELETE cancels: the run is finalized with
  `outcome:"error"` and no result (a finished run is returned unchanged).

### Errors and HTTP statuses

The debate calls answer success with HTTP 200 and errors with `{ "ok": false, "code" }` and the code's status. Of these
answers only 503 (`unavailable`, `not_ready`) is retryable; the server also backs off and retries a 429 for `finalize`
rather than dead-letter a paid result. A response that is not a contract answer (a status without its matching
`{ "ok": false, "code" }` body, a timeout, a redirect) is a service failure: a `finalize` stays in the outbox and is retried.

<!-- conformance:debate-codes -->
| Call | Code | HTTP | Meaning |
|---|---|---|---|
| `finalize` | `invalid` | 400 | the body does not match the schema |
| `finalize` | `not_found` | 404 | no such reservation |
| `finalize` | `conflict` | 409 | a different body for a finalized reservation, or an id bound elsewhere |
| `finalize` | `too_large` | 413 | the body is over 512 KB |
| `finalize` | `rate_limited` | 429 | slow down (retried) |
| `finalize` | `unavailable` | 503 | try again later (retried) |
| `finalize` | `not_ready` | 503 | the service cannot take it yet (retried) |
| `fetch` | `invalid` | 400 | the request does not match the schema |
| `fetch` | `not_found` | 404 | no such debate for this principal |
| `fetch` | `rate_limited` | 429 | slow down |
| `fetch` | `unavailable` | 503 | try again later |
| `fetch` | `not_ready` | 503 | try again later |
| `authorize-run` | `invalid` | 400 | the request does not match the schema |
| `authorize-run` | `not_found` | 404 | no such reservation |
| `authorize-run` | `conflict` | 409 | an id is bound to another counterpart, or the reservation is not held |
| `authorize-run` | `rate_limited` | 429 | slow down |
| `authorize-run` | `unavailable` | 503 | try again later |
| `authorize-run` | `not_ready` | 503 | try again later |
<!-- /conformance:debate-codes -->

### Canonical bodies and fixtures

Bodies are compared in canonical form: object keys sorted recursively by UTF-16 code unit (so `"10"` sorts before `"9"`),
array order kept, standard JSON string escaping, no insignificant whitespace. `docs/external-auth/debate-fixtures.json`
pins the canonicalization, the section-boundary truncation and valid and invalid examples of every request and response;
the conformance runner checks them and the hashes in `CONTRACT-VERSION`. The schemas are the wire-format source of truth;
the rules above about ownership, charging, durability and gating stay normative where a schema cannot express them.

### Privacy

Questions, answers and transcripts never appear in logs, stats, `--outbox-status`, `--outbox-export` (finalize records
are exported without them) or dead-letter records. They exist only in the mode-0600 metering intent and outbox record
until delivery, and in the service.

## Implementer's security checklist

Before putting a service in front of real money, confirm each item (the conformance runner covers the protocol, not these):

- [ ] Customer keys are stored hashed (SHA-256 of a high-entropy key, or slower for low-entropy ones), shown once, never logged.
- [ ] Key hashes and the service token are compared in constant time.
- [ ] `introspect` and `health` are rate-limited per source and globally; unknown keys cost the service one hash and one lookup.
- [ ] `reserve` checks `balance - holds` and creates the hold in one atomic step (a transaction or a conditional update).
- [ ] The state machine above is implemented exactly, including the idempotency rules: same `request_id` returns the same reservation; same `reservation_id` with the same `settle` payload is `ok`, with a different payload is `conflict`; `release` is always `ok`.
- [ ] Expiry sweeps release held funds, but a `settle` that arrives later for an expired reservation is still accepted and charged (retained settle liability); the server delivers at least once and may be minutes or hours late.
- [ ] Audit records (who, which reservation, amounts, outcome, time) exist for every state change and contain no key or token.
- [ ] Service token rotation is possible without downtime (accept old and new for a window); a 401/403 to the server is a configuration failure that dead-letters the record, so rotate before revoking.

## Operator runbook

Check state with `e3d-mcp --doctor`, the `e3d_usage` tool, `e3d-mcp --outbox-status`, and `GET /readyz` (503 with `reasons`). None of them print a credential or a URL path.

**What a readiness failure means**

- `auth service health check failed`: the last background `GET /health` did not answer. New requests fail with 503 until it does; running debates still settle (into the outbox if needed). Check the service, then `E3D_MCP_AUTH_URL` and the service token.
- `dead-letter records need an operator`: a settle or release was refused permanently (a `conflict`, or a 401/403 that means a wrong service token). Reconcile below.
- `dead-lettered settlements`: `E3D_MCP_OUTBOX_MAX_DEAD` (default 1) dead records stop new billed work until an operator retries them with `--outbox-retry-dead`.
- `outbox is at its bound`: `E3D_MCP_OUTBOX_MAX` undelivered records, or `E3D_MCP_OUTBOX_MAX_BYTES` (default 64 MB) of them. New billed work is refused until delivery drains it; usage already run is never discarded.
- A dead `finalize.reservation_id.<id>` record: the service gave a terminal answer (the reason shows the code). The record keeps ids and usage only, so it cannot be retried; reconcile the reservation with the service by its id.

**Reconciling dead records**

1. `e3d-mcp --outbox-status` lists each dead record: id, call, age, reason.
2. `e3d-mcp --outbox-export dead.json` writes pending and dead records with payloads (mode 0600, no tokens). Compare the reservation ids with the service's ledger.
3. Fix the cause: for a `conflict`, decide what the account should be charged and correct the service's record; for 401/403, fix the service token and restart.
4. `e3d-mcp --outbox-retry-dead <record_id>` moves that one record back to pending. Delivery is idempotent, so a repeat cannot double-charge. Repeat per record.

**After a billing outage**

Nothing to do for correctness: pending settlements are retried with backoff (30 s up to 15 min) and drain on their own once the service answers. Watch `e3d-mcp --outbox-status` until pending is 0. Records older than 72 h show as stale; the service must still accept them (retained settle liability). If the server crashed in the meantime, intents are replayed at startup and unfinished debates are charged or released per `E3D_MCP_ORPHAN_POLICY` (see the count of recovered orphans in `e3d_usage`).
