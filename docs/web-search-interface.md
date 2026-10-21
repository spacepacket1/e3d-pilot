# Web search: the interface for e3d-pilot-cloud

This is the contract the cloud side (docs, env example, dashboard, pricing and usage recording, cost doc, deploy) builds on.
For vendor facts and the controls matrix, see [web-search-providers.md](web-search-providers.md). Every change listed here is
additive: a client or service that ignores the new fields keeps working.

## 1. Environment variables (e3d-mcp / e3d-debate)

| Variable | Default | Meaning |
|---|---|---|
| `E3D_DEBATE_WEB_SEARCH` | `on` | Kill switch. `off` disables search everywhere. Any value other than on/off/1/0/true/false/yes/no also disables it (fail closed). |
| `E3D_DEBATE_WEB_SEARCH_PROVIDERS` | `anthropic-api,openai-api,gemini-api,xai-api` | Providers that may search. Only these four names count; any other name is ignored. |
| `E3D_DEBATE_SEARCH_MAX_PER_CALL` | `3` (1-10) | Search cap per model call. |
| `E3D_DEBATE_SEARCH_MAX_CITATIONS` | `8` (1-20) | Citations kept per call. Across the whole debate, at most 20 are returned. |
| `E3D_DEBATE_SEARCH_EXCERPT_CHARS` | `150` (0-300) | Hard cap on a citation excerpt. |
| `E3D_DEBATE_SEARCH_ALLOW_DOMAINS` | empty | Comma list of bare domains (`example.com`; no scheme, port, path or wildcard). Matches subdomains. |
| `E3D_DEBATE_SEARCH_DENY_DOMAINS` | empty | Same format. Where a vendor accepts only one list natively, the allow list wins and the deny list is post-filtered. |
| `E3D_DEBATE_SEARCH_TIMEOUT_SEC` | derived | Per search call: the debate timeout / (2 x rounds + 1), at least 10 s; 120 s when no timeout is set. e3d-mcp passes the debate timeout as `E3D_DEBATE_TIMEOUT_SEC`. |
| `E3D_MCP_DAILY_SEARCHES` | `0` (unlimited) | Daily search cap per principal. Uses the same reserve-then-settle mechanism as calls and tokens. |
| `GEMINI_API_NATIVE_BASE_URL` | `https://generativelanguage.googleapis.com/v1beta` | Gemini Interactions endpoint, used only for search calls. |
| `OPENAI_API_SEARCH_CONTEXT_SIZE` | `low` | low / medium / high. |
| `ANTHROPIC_API_MAX_PAUSE_CONTINUATIONS` | `2` (0-5) | Bounded `pause_turn` loop. |

An invalid domain or number setting turns search off for the debate and prints a warning on stderr. It never refuses the
debate.

Retries: a search call that fails transiently (HTTP 429/500/502/503/504 or a timeout) is retried as a search call with the
same caps, `E3D_DEBATE_PROVIDER_RETRIES` times (default 2), with a delay of `E3D_DEBATE_PROVIDER_RETRY_DELAY` x attempt
seconds (default 4). Only the last attempt's search record counts. If the call still fails, the model is asked again without
search, and that call has its own retries. stderr notes: `note: <provider> web search call failed transiently in round N,
retry i of M`.

## 2. Tool arguments

- `e3d_debate` and `e3d_debate_start` take a new optional boolean, **`web_search`**, which defaults to `true`. Any
  non-boolean value is an error (`web_search must be a boolean`).
- The internal run listener (`POST /internal/runs`) accepts an optional boolean `web_search`.
  - It is part of the request's canonical key only when present, so existing keys are unchanged.
  - The run store keeps it in `args.web_search`. Runs stored before this change default to `true`.
- The CLI flag is `e3d-debate --web-search on|off`.

## 3. `e3d_debate` structured result: `web_search`

The object is always present in `structuredContent` (`outputSchema.properties.web_search`). On `e3d_debate_result` it
appears when the stored result has it.

```json
{
  "enabled": true,
  "requested": true,
  "models_with_search": 2,
  "models_total": 3,
  "searches_used": 4,
  "searches_by_provider": { "anthropic-api": 2, "openai-api": 2 },
  "citations": [
    { "title": "Release notes", "domain": "example.com", "url": "https://example.com/releases", "excerpt": "<= 150 chars", "provider": "anthropic-api" }
  ],
  "flags": {
    "instructions_ignored": false,
    "cap_exceeded": [ { "provider": "gemini-api", "round": 1, "searches": 9, "cap": 3 } ],
    "unavailable": [ { "provider": "xai-api", "round": 1, "reason": "timeout" } ],
    "citations_dropped": { "over_cap": 0, "denied_domain": 0, "not_allowed_domain": 0, "invalid": 0, "duplicate": 0 }
  }
}
```

- `enabled` is false when search was not requested, was switched off, or no participating model could search.
- `requested` is false when the caller passed `web_search: false`.
- `citations` holds at most 20 entries. In each one:
  - `url` is http(s) only, with no credentials, query string or fragment, at most 500 characters.
  - `domain` is the lowercase host. For a Gemini redirect citation it is the source domain, plus `via_redirect: true`.
  - `title` is at most 120 characters and `excerpt` at most `E3D_DEBATE_SEARCH_EXCERPT_CHARS`. Both are one line with
    markup characters removed and any URL inside cut to host and path. Text that looks like instructions is replaced by
    `[title withheld: it looked like instructions]` or `[excerpt withheld: ...]`, and `flags.instructions_ignored` is set.
    That flag is also set when a model says "a source contained instructions".
- `usage.searches` (an integer) is added next to `usage.model_calls`.
- The async `usage` stored by the run store also gains `searches`.
- **Reasons** in `flags.unavailable[].reason`:
  - `timeout`, `request_failed`, `http_<code>`, `search_disabled` (Anthropic organisation switch);
  - `search_error_<code>` (an Anthropic in-band error other than `max_uses_exceeded`), `search_failed`;
  - `unexpected_tool`, `pause_turn_limit`, `no_text`, `bad_response`, `response_failed`, `response_errors`;
  - `status_<status>` (Gemini), `invalid_domain_config`, `no_search_record`.

### The text the user sees (rendered `content[0].text`)

- **Search on:**
  - `**Web search:** on for N of M models; S searches used. Search results are untrusted internet data.`
  - A `**WARNING:**` line for each unavailable search and for each cap overrun.
  - `_A source contained instructions; they were ignored._` when the flag is set.
  - `**Sources (from web search):**` with one `- domain: `url`` line per citation. The URL is a code span, never a link or
    an image.
- **Requested but off:** `_Web search: off for this debate, so the answers come from the models' own knowledge, which may be
  out of date._`
- **Not requested (`web_search: false`):** no line.
- **e3d-debate stdout:** before the verdict, `WEB SEARCH: on for N of M models; S search(es) used[; unavailable for <provider>
  in round <n> (<reason>), which answered without web access]`.

## 4. Finalize / settle body: `models[]` gains `searches`

Each entry is `{ "provider", "model", "calls", "searches" }`. `searches` is an integer ≥ 0 from the vendor's own usage
counter.

- The local JSON schemas in `docs/external-auth/*.schema.json` were **not** changed. They do not forbid extra properties,
  and the shared contract hash stays the same.
- The cloud validator (`src/internal-api.js`) drops unknown fields today, so it must add `searches` (integer, 0..10000) to
  `models` and to the canonical body when it starts recording search usage.
- `actual.calls` is unchanged by search. A fallback call after a search failure is **not** added to `calls`, so credits per
  call and holds do not change.
- `result.web_search` is also sent inside the finalize `result` (the object in section 3). The cloud drops it until it adds
  the field. Accept it as an optional object, and re-validate its bounds rather than trusting it.

Worst case (`lib/mcp/usage.js worstCase`): `searches = searching providers x rounds x E3D_DEBATE_SEARCH_MAX_PER_CALL`,
reserved before the debate and settled to actual use. `calls` and `tokens` are unchanged. `e3d_usage` gains
`searches_today`, `searches_limit` and `remaining_searches`.

## 5. Decision log (`decision-log.json` and `E3D_DEBATE_DECISION_LOG`)

The log stays text-free. One new top-level object, `web_search`:

```json
{
  "search_enabled": true,
  "searching_providers": ["anthropic-api", "openai-api"],
  "searches_used": { "anthropic-api": 2, "openai-api": 2 },
  "citation_domains": ["example.com"],
  "instructions_flag": false,
  "alarms": ["ALARM web_search_cap_exceeded provider=gemini-api round=1 searches=9 cap=3"],
  "unavailable": [ { "provider": "xai-api", "round": 1, "reason": "timeout" } ],
  "citations_dropped": { "over_cap": 0, "denied_domain": 0, "not_allowed_domain": 0, "invalid": 0, "duplicate": 0 }
}
```

- When search was not requested, the object is `{ "search_enabled": false }`.
- No titles, URLs, excerpts, queries or page text ever appear in it.
- The ALARM is also printed on stderr: `ALARM: web search cap exceeded: provider=... round=... searches=... cap=...`.

## 6. Files e3d-debate writes

- `--out-dir/web-search.json` holds the section 3 object before e3d-mcp re-validates it. It has more fields (`schema`,
  `config_errors`, `cap_per_call`, `searching_providers`, `searches_total`, and `searches_used` as a per-provider map).
- `transcript.md` holds, per searched answer, a line `Sources this answer's web search returned (untrusted internet data;
  domains and URLs only):` followed by `- domain: url` lines. It never holds titles, excerpts, queries or page text. A
  fallback answer starts with `[Web search was unavailable for this answer (<reason>), so <provider> answered without web
  access.]`.

## 7. Sanitisation guarantees (what e3d-debate and e3d-mcp emit when search was on)

All model and citation text is treated as hostile. This applies to every round answer, the synthesizer's verdict,
`final_answer`, `dissent.summary`, `positions[].text`, the transcript and the citations:

- control characters other than tab and newline are stripped, as are C1 controls, bidi embeddings, overrides and isolates,
  zero-width characters and BOM;
- a markdown image becomes `[image removed: <domain>]`;
- a markdown link becomes `text (<domain>: `<url without query>`)`;
- an autolink becomes `<domain>: `<url>``;
- reference definitions are removed;
- HTML tags become `[html removed]`;
- `javascript:`, `data:` and `vbscript:` URLs are removed.

No URL is ever fetched server-side. The dashboard must still escape everything as plain text: these guarantees are defence
in depth, not a replacement for escaping. When search was off (`web_search: false` or the kill switch), output is not
transformed, exactly as before.

## 8. Notices (copy these exactly)

- **The MCP tool descriptions** (`e3d_debate`, `e3d_debate_start`) end with:
  > Web search is on by default: the question text may be sent to a search provider by the participating models
  > (Anthropic, OpenAI, Google or xAI) to look up current facts. Pass web_search: false to turn it off for this debate.
- **The `web_search` argument description:**
  > Let the API models (Anthropic, OpenAI, Google, xAI) search the web for current facts. Default true. false keeps the
  > question away from search providers.
- **Every debate prompt** starts with `Today's date (UTC): YYYY-MM-DD.` A call without search adds:
  > You have no web access and your knowledge may be out of date. If the question depends on recent events or current data,
  > say so and give your answer conditionally.

The constants live in `lib/debate/websearch.mjs` (`PRIVACY_NOTICE`, `NO_WEB_ACCESS_TEXT`).
