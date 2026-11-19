# OpenRouter voices

Phase 0 of the multi-model expansion: one transport adapter, `lib/providers/openrouter`, reaches several model families through OpenRouter. It adds four voices for manual use next to the existing direct adapters. No default changes: nothing here is chosen automatically, and the hosted service does not offer these voices yet.

## What is what

| Term | Here |
|---|---|
| Transport | `lib/providers/openrouter` (one adapter, one API key) |
| Voice | A council seat: `or-deepseek`, `or-glm`, `or-minimax`, `or-mistral`. Each is a thin script that sets `E3D_OPENROUTER_VOICE` and runs the transport. |
| Model | The exact upstream id in `lib/providers/openrouter-models.json` (`model_id`, with the dated `pinned_slug` recorded beside it) |
| Family | `family_id` in the registry. Independence counts families, never adapters. |

Four voices on one adapter are four seats. A model that already has a direct adapter (Claude, GPT, Gemini, Grok) is never routed through OpenRouter: the registry validator (`lib/debate/model-registry.mjs`) refuses those families, so "GPT direct" and "GPT through OpenRouter" cannot be counted as two independent voices.

## The four voices

Checked against OpenRouter's public models API on 2026-11-19. Prices are USD per token, the highest figure listed, and are a reference only.

| Voice | Model id | Family |
|---|---|---|
| `or-deepseek` | `deepseek/deepseek-v4.1-flash` | deepseek |
| `or-glm` | `z-ai/glm-5.3-flash` | glm |
| `or-minimax` | `minimax/minimax-m3.1-flash` | minimax |
| `or-mistral` | `mistralai/mistral-small-2603` (Mistral Small 4) | mistral |

Not production defaults. Every voice has `auto_eligible: false` until the evaluation framework has measured it. Moving aliases such as `~deepseek/deepseek-flash-latest` are refused by the validator.

## Use

```
OPENROUTER_API_KEY_FILE=~/.config/e3d-pilot/openrouter-key \
  bin/e3d-debate "question" --providers anthropic-api,or-deepseek,or-glm --rounds 1
bin/e3d-pilot providers list      # the or-* voices show unavailable until a key is set
```

The key is read from `OPENROUTER_API_KEY` or `OPENROUTER_API_KEY_FILE` (a file holding the key, or an `export OPENROUTER_API_KEY=...` line, mode 0600). It is sent from a 0600 header file, never on a command line, and never printed.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `OPENROUTER_MAX_TOKENS` | none | Output limit (`max_tokens`). Reasoning tokens count against it. |
| `OPENROUTER_DATA_COLLECTION` | `deny` | `deny` routes only to endpoints that do not keep or train on prompts. If none qualifies the call fails with HTTP 404; it never falls back. |
| `OPENROUTER_ZDR` | off | `1` also requires zero-data-retention endpoints. |
| `OPENROUTER_ONLY` | none | Comma list of upstream providers to use exclusively. |
| `OPENROUTER_ALLOW_FALLBACKS` | `1` | `0` forbids OpenRouter trying another endpoint of the same model. |
| `OPENROUTER_REASONING_EFFORT` | none | `low`, `medium` or `high`. |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` | |
| `OPENROUTER_TIMEOUT` | `180` | seconds |

Every request sets `require_parameters`, so an endpoint that cannot honor `max_tokens` is skipped instead of ignoring it.

## What the adapter reports

The usage line (`e3d_provider_usage=`) names the voice, the model OpenRouter says it served, normalized input and output tokens (an empty reply is still counted), and a `routing` object: the requested model, OpenRouter's request id, the upstream provider that served it, and the cost it returned. Errors say `HTTP <code>`, so the engine's retry rule treats 429 and 5xx as transient and 401, 402 and 404 as final. A 200 with an error body is handled as the failure it is.

## Not done yet (later phases)

- Hosted exposure: the billing service's provider allowlist and family map, per-token quoting and the rate table do not know these voices. Extend them together before offering any voice hosted.
- No web search: these voices are not search-capable.
- Automatic selection, tiers and the evaluation suite.
- Region restrictions: not enforced; `privacy_attributes` in the registry say `unverified` until each endpoint is checked.
- Pricing refresh from the models API (the registry holds a dated snapshot; a failed refresh must never replace it with zero).

## Tests

`bash tests/openrouter.sh` runs against a fake local server. `E3D_LIVE_OPENROUTER=1 bash tests/openrouter-live.sh` makes one tiny real call per voice and spends a fraction of a cent; it is never part of the normal suite.
