# Web search in debates: what each vendor allows, what we add, what risk remains

Status: built 2026-10-21 for the four API providers. All four can search, on by default. Every vendor fact below was re-read
on 2026-10-21 from the vendor's own documentation (links given). Anthropic pages were read in full. The OpenAI, Google and
xAI pages were read through a fetch tool that summarises long pages, so their quotes are close to the original but may not
be exact. Anything not found is marked **not documented**, and we do not rely on it.

The fake-server tests in `tests/web-search.sh` cover every control in the matrix. Nothing in this document has been tried
against the real vendor APIs: run one real debate per provider before relying on it in production (see "Before production").

## Design in one paragraph

Only the four API providers ever get a search tool, and only in the debate rounds. The synthesizer never searches. Each
search call is given exactly one tool: the vendor's own web search. There is no file access, shell, code execution, MCP tool
or URL fetching by us. The system layer of each call states that search results are untrusted data. That is a hint to the
model, not a security boundary. We never see raw page text: we keep only the vendor's citations, which are a title, a URL
and, for Anthropic only, an excerpt of up to 150 characters. Those citations are post-filtered, capped and sanitised. Later
rounds and the synthesizer see the other models' answers plus a list of domains and URLs, never titles, excerpts or page
text. If search fails in any way, that model is asked again without search, and the answer says so.

## Vendor facts (verified 2026-10-21)

### Anthropic (`anthropic-api`, Messages API)

Sources: https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool and
https://platform.claude.com/docs/en/agents-and-tools/tool-use/server-tools

- **Tool version.** We use `web_search_20250305`, the basic version. The `_20260209` versions "default to the code execution
  caller only; earlier versions default to `["direct"]`", so newer versions would bring in code execution as a second tool.
  The basic version is also eligible for zero data retention.
- **Tool definition.** `{"type":"web_search_20250305","name":"web_search","max_uses":N,"allowed_domains":[...]}` or
  `"blocked_domains":[...]`.
- **Domain lists.** "Provide `allowed_domains` or `blocked_domains`, not both" (both gives a 400). Entries are bare domains
  without a scheme, and "Subdomains are automatically included".
- **Search cap.** `max_uses` caps searches per request. Going over it gives a result error `max_uses_exceeded`.
- **Errors.** A search error arrives inside a 200 as `{"type":"web_search_tool_result_error","error_code":...}`. The codes are
  `too_many_requests`, `invalid_tool_input`, `max_uses_exceeded`, `query_too_long`, `request_too_large` and `unavailable`.
- **Organisation switch.** An organisation can disable web search. A request then "fails with a 400 `invalid_request_error`
  that says web search is not enabled".
- **Citations.** `web_search_result_location` carries `url`, `title`, `cited_text` ("Up to 150 characters") and
  `encrypted_index`. Results carry `url`, `title`, `encrypted_content` and `page_age`. Page content is encrypted, so we
  never see it.
- **Usage.** `usage.server_tool_use.web_search_requests`.
- **pause_turn.** "Pass the paused response back as-is", with the same tools. A continuation can pause again. If
  `encrypted_content` is missing or changed, the request fails with a 400.
- **Price.** "$10 per 1,000 searches, plus standard token costs". A failed search is not billed.

### OpenAI (`openai-api`, Responses API when searching)

Sources: https://developers.openai.com/api/docs/guides/tools-web-search,
https://developers.openai.com/api/reference/resources/responses/methods/create and https://developers.openai.com/api/docs/pricing

- **Endpoint.** The `web_search` tool exists only on the Responses API. Chat Completions has only search models that always
  search, so search-off keeps the original Chat Completions path unchanged.
- **Tool fields.**
  - `filters.allowed_domains` and `filters.blocked_domains`: up to 100 each, no protocol, subdomains included. Whether both
    can be used at once is **not documented**, so we never send both. The API reference lists only `allowed_domains`;
    `blocked_domains` is in the guide.
  - `search_context_size`: low, medium (the default) or high.
  - `external_web_access`: "Defaults to true when omitted".
- **Request fields.**
  - `max_tool_calls`: "The maximum number of total calls to built-in tools that can be processed in a response". This is our
    cap.
  - `max_output_tokens`, `instructions` ("A system (or developer) message"), `store` (we send `false`), `tool_choice`, and
    `include: ["web_search_call.action.sources"]`.
- **Output.**
  - `web_search_call` items carry `status` and an `action` whose type is `search`, `open_page` or `find_in_page`. **The tool
    can open pages itself.** This cannot be turned off; it happens inside OpenAI, not on our servers.
  - `message` → `output_text` → `annotations[]` of type `url_citation` {url, title, start_index, end_index}.
  - `output_text` at the top level is an SDK convenience only, so we collect the text items ourselves.
- **Status and errors.** `status` is completed, failed, in_progress, cancelled, queued or incomplete. The `error` object
  has `code` and `message`; the list of error codes is **not documented**.
- **Price.** "Web search ... $10.00 / 1k calls + Search content tokens billed at model rates".

### Google Gemini (`gemini-api`, Interactions API when searching)

Sources: https://ai.google.dev/gemini-api/docs/google-search, https://ai.google.dev/api/interactions-api,
https://ai.google.dev/gemini-api/docs/interactions and https://ai.google.dev/gemini-api/docs/openai

- **Endpoint.** The search guide documents only `POST https://generativelanguage.googleapis.com/v1beta/interactions` with
  header `x-goog-api-key` and `tools:[{"type":"google_search"}]`.
  - The OpenAI-compatible endpoint, which our search-off path uses, mentions Google Search only for an image model. So
    search calls go to the Interactions API, and search-off stays on the OpenAI-compatible endpoint, unchanged.
  - The generateContent reference documents `groundingMetadata`, but we do not use it.
- **Request fields (API reference).** `model`, `input`, `system_instruction`, `tools`, `store` ("Whether to store the
  response and request for later retrieval"; we send `false`) and `generation_config.max_output_tokens`.
  - The `google_search` tool has one optional field, `search_types`, which takes `web_search`, `image_search` or
    `enterprise_web_search`. We send `["web_search"]` so image search stays off.
- **Response.** `status` is in_progress, requires_action, completed, failed, cancelled, incomplete or queued.
  - `steps[]` holds `model_output` steps, whose content has `text` with `annotations` of type `url_citation` {url, title,
    start_index, end_index}, plus `google_search_call` (`arguments.queries`) and `google_search_result`
    (`search_suggestions`, an HTML snippet). We discard the snippet unread.
  - `usage` has `total_tokens` and `grounding_tool_count[]` {type, count}.
  - The reference shows the search steps as streaming deltas. The non-streaming step schema was cut off in what we could
    read, so the parser fails closed on any step type it does not know.
- **No domain control and no query cap are documented.** The model "automatically generates one or multiple search queries",
  and each is billed. The Java SDK says of `excludeDomains`: "This field is not supported in Gemini API."
- **Price.** Gemini 3 and newer: 5,000 free search requests a month, then $14 per 1,000. Gemini 2.5 and older are billed per
  prompt.
- **Redirect URLs (not documented).** Third-party reports say grounding URLs may be
  `vertexaisearch.cloud.google.com/grounding-api-redirect/...` redirect URLs, with the source domain as the title. If that
  happens, we take the domain from the title for filtering and mark the citation `via_redirect`.

### xAI (`xai-api`, Responses API when searching)

Sources: https://docs.x.ai/docs/guides/tools/search-tools, https://docs.x.ai/docs/api-reference,
https://docs.x.ai/developers/tools/citations, https://docs.x.ai/developers/tools/tool-usage-details,
https://docs.x.ai/developers/tools/advanced-usage and https://docs.x.ai/docs/pricing

- **Request.** `POST https://api.x.ai/v1/responses` with `tools:[{"type":"web_search"}]`.
- **Domain lists.** Inside `filters`: `allowed_domains` (max 5) or `excluded_domains` (max 5). They "cannot be set together".
- **Image options.** `enable_image_understanding` and `enable_image_search` sit on the tool. We send both as `false`.
- **Request fields.** `input` (role messages; our system text is a `system` message), `store`, `max_output_tokens` and
  `max_turns` ("Maximum number of agentic tool calling turns allowed for this request"; it "only limits the
  assistant/server-side tool call turns").
  - **A per-call search cap (`max_tool_calls`) is not documented.**
- **Output.** `web_search_call` output items; their fields are **not documented**. Annotations are `url_citation` {url,
  start_index, end_index, title}, where the title is a number label. There is also a `citations` list of every URL seen,
  shown via the SDK; its raw JSON key is **not documented**, so we read it only if present.
- **Usage.** `server_side_tool_usage_details.web_search_calls`. Only successful calls are billed.
- **Price.** Web search is $5 per 1,000 calls.
- **Image search.** It returns Markdown image embeds, which is another reason it stays off.

## Controls matrix

"Native" means the vendor enforces the control before the model sees anything. "Compensating" means we enforce it on our
side after the call.

| Control | Anthropic | OpenAI | Gemini | xAI |
|---|---|---|---|---|
| Search is the only tool | native: one tool, basic version; any other block type fails closed | native: one tool; any other output item type fails closed | native: one tool, web results only; any unknown step fails closed | native: one tool, image options off; any other output item type fails closed |
| Search cap per call (default 3) | native `max_uses`, also checked after the call | native `max_tool_calls`, also checked after the call | **none**: checked after the call, ALARM | `max_turns` (turns, not searches), checked after the call, ALARM |
| Page opening | the vendor may fetch pages; we get encrypted content | **the tool opens and searches pages itself** | not documented | not documented |
| Allow list | native `allowed_domains` | native `filters.allowed_domains` (up to 100) | **none**: post-filter only | native when 5 or fewer, else post-filter only |
| Deny list | native `blocked_domains` when there is no allow list; else post-filter | native `filters.blocked_domains` when there is no allow list; else post-filter | **none**: post-filter only | native `excluded_domains` when 5 or fewer and no usable allow list; else post-filter |
| Excerpt kept | vendor's 150 characters, cut to our cap | none (title and URL only) | none | none |
| Citations kept (default 8), excerpt cap, URL without query string, sanitised | ours | ours | ours | ours |
| Wall-clock limit | ours: curl `--max-time`, shared by `pause_turn` continuations (at most 2) | ours | ours | ours |
| Output ceiling | `max_tokens` (4096 by default) | `max_output_tokens` (8192 by default) | `generation_config.max_output_tokens` (8192 by default) | `max_output_tokens` (8192 by default) |
| Token ceiling (`E3D_PILOT_PROVIDER_TOKEN_LIMIT`) | ours | ours | ours | ours |
| Search disabled at the vendor | the 400 is recognised; fail closed | any error fails closed | any error fails closed | any error fails closed |
| Kill switch, per-provider switch, per-debate switch | ours | ours | ours | ours |
| Search counted for the daily cap and finalize `models[].searches` | `usage.server_tool_use.web_search_requests` | `web_search_call` items (every action counted) | `usage.grounding_tool_count`, else the query list | `usage.server_side_tool_usage_details.web_search_calls`, else `web_search_call` items |

### Residual risk, per provider

- **Anthropic: lowest.** Every control is native.
  - The model still reads the pages the vendor fetched. Our framing text and post-filters cannot stop a page from steering
    the model's own answer; they only keep page text out of other models' prompts and out of our outputs.
- **OpenAI: medium.** The search cap and both domain lists are native.
  - The tool can open pages and search inside them. That is inherent to the tool and cannot be switched off. The pages
    opened are inside OpenAI's own tool, not our servers.
  - `max_tool_calls` counts every built-in tool call, so opening a page uses up the cap.
  - Using both domain lists at once is not documented. The allow list wins, and the deny list is post-filtered. A denied
    domain can still be read by the model; we only drop its citation and count it.
- **Gemini: highest.**
  - There is no domain control and no query cap. The model decides how many billable queries to run. We can only see the
    count after the call, raise an ALARM, and count it against the daily search cap.
  - Denied domains are dropped from the citation list only. **The model may already have read them.**
  - The Interactions API's non-streaming response shape is only partly documented. An unexpected shape fails closed, so
    Gemini may simply fall back to answering without search.
  - Run a real call before production to confirm the shape.
- **xAI: medium-high.**
  - There is no documented per-search cap. `max_turns` limits tool-calling turns, and one turn may hold several searches.
    The count is checked after the call, with an ALARM.
  - Domain lists hold at most 5 entries; longer lists are post-filtered only.
  - The shape of `web_search_call` and of the raw citations list are not documented.

### Shared residual risk, all providers

- **Prompt injection into the searching model.** Every safeguard against a page steering that model's own answer is
  best-effort. The framing text is a hint. Our real controls limit what the hostile text can reach:
  - no tools other than search, so it can trigger no actions;
  - no raw page text to other models;
  - images, links and HTML neutralised in everything we emit;
  - no secrets in any prompt;
  - no URL fetched by our servers.
- **The question goes to the vendor's search backend.** The models write the queries themselves from the question. We do not
  see or log those queries, and we cannot strip personal data out of them. That is why there is a privacy notice and
  `web_search: false`.
- **A fallback call costs one extra model call.** It is not added to the charged `calls`, so pricing does not change.
- **Gemini and xAI over-cap searches** are billed by the vendor before we can see them. The ALARM and the daily search
  cap bound the damage over a day, not within one call.

## What we never do

- Fetch a citation URL server-side.
- Pass titles, excerpts, page text or search queries to another model.
- Write queries or page text to stderr, the work directory, the transcript or the decision log. The transcript holds each
  answer's domain/URL list. `web-search.json` holds the bounded, sanitised citation list (title, domain, URL, excerpt up to
  the cap; `E3D_DEBATE_SEARCH_EXCERPT_CHARS=0` removes excerpts).
- Put secrets, environment values or account data into a prompt. Keys stay in 0600 header files, never on argv, and are
  never printed.
- Let web content change pricing, credits, holds or settlement:
  - searches are recorded as usage (`models[].searches`, the daily search cap) and never change `calls`;
  - the worst case adds `searches = cap x searching calls`;
  - credits are charged per call as before.

## Before production

1. For each vendor, check that the configured model accepts the search tool. For Anthropic, that is
   `capabilities.server_tools.web_search.supported` in the Models API. If a model does not, its search calls fail closed
   and it answers without search.
2. Run one real debate per provider and compare the response shape with this document, especially Gemini's Interactions
   steps and xAI's `web_search_call` and usage fields.
3. Set `E3D_MCP_DAILY_SEARCHES` for hosted mode. It is unlimited by default.
