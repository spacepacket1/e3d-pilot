# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant, explicitly selected `gemini` provider adapter for `e3d-debate`. It must invoke Gemini CLI headlessly, accept prompts through stdin, preserve provider exit-code and telemetry conventions, reject paid or ambiguous authentication, enforce timeout and token ceilings, and never approve or execute Gemini tool calls.

## Goals

- Add `lib/providers/gemini` using the existing provider contract and shared helpers.
- Support availability checks, dry runs, headless execution, timeouts, structured response parsing, and usage telemetry.
- Permit only positively confirmed free personal OAuth use; never automatically use API-key or Vertex AI billing paths.
- Add isolated stub-based tests covering the adapter and explicit participation in `bin/e3d-debate`.
- Document installation, authentication, environment variables, safety behavior, and opt-in scope.

## Non-Goals

- Adding Qwen3 Coder, OpenRouter, or another provider adapter.
- Modifying `lib/providers/local`, `lib/providers/common.sh`, `bin/e3d-debate`, or `config.schema.json`.
- Changing any default provider, synthesizer, pipeline-stage, or example configuration.
- Adding Gemini to `.e3d-pilot/config.json` or any `providers.*` value.
- Running or scoring the proposed historical Gemini debate trial.
- Supporting paid Gemini API-key, Google Cloud, or Vertex AI authentication.
- Enabling Gemini CLI tools, automatic approvals, `--yolo`, or repository mutation.

## Existing Files

- `lib/providers/common.sh` defines the provider contract, prompt-file validation, binary availability checks, and timeout helper.
- `lib/providers/claude` demonstrates JSON parsing, token-limit enforcement, and usage telemetry with an unmeasured fallback.
- `lib/providers/codex` demonstrates read-only, non-interactive provider execution.
- `lib/providers/devin` and `lib/providers/grok-build` demonstrate optional model overrides and timeout handling.
- `bin/e3d-debate` dynamically resolves explicitly named `lib/providers/<name>` adapters.
- `tests/phase33.sh` is the current highest-numbered phase test.
- `README.md` documents built-in adapters in "Providers and negotiation."
- `docs/debates/2026-09-15-gemini-qwen-provider-addition/transcript.md` records the decision and scope for this trial adapter.

## Shared Constraints

- The complete implementation must modify no more than three files and remain comfortably within 1,400 changed lines.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, or `.e3d-pilot/**`.
- Preserve the provider exit-code contract: `0` for success, `1` for an available provider whose invocation or validation fails, and `2` when the configured binary is unavailable.
- The prompt must be accepted only as the required `$1` prompt-file argument and validated with `provider_require_prompt_file`.
- Prompt content must reach Gemini CLI through stdin or an equivalent file-reading mechanism; it must never be expanded into an argv argument.
- Gemini must remain opt-in through explicit adapter naming. Do not alter defaults, configuration examples, schemas, pipeline wiring, or debate synthesizer behavior.
- Never enable Gemini CLI tools or automatic tool approval. Do not pass `--yolo` or an equivalent option.
- Tests must use temporary directories and stub binaries, must not require Gemini CLI installation or network access, and must not read or overwrite a developer's actual Gemini credentials.
- Keep shell code compatible with the Bash conventions already used by the provider adapters and phase tests.

## Phase 1 - Implement and Document the Gemini Trial Adapter

<!-- runner:model=codex:gpt-5.6-sol -->
<!-- pilot:touches=lib/providers/gemini -->
<!-- pilot:touches=tests/phase34.sh -->
<!-- pilot:touches=README.md -->
<!-- runner:read=lib/providers/common.sh -->
<!-- runner:read=lib/providers/claude -->
<!-- runner:read=lib/providers/codex -->
<!-- runner:read=lib/providers/devin -->
<!-- runner:read=lib/providers/grok-build -->
<!-- runner:read=bin/e3d-debate -->
<!-- runner:read=tests/phase33.sh -->
<!-- runner:read=docs/debates/2026-09-15-gemini-qwen-provider-addition/transcript.md -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and require exactly one positional argument: the prompt-file path, validated with `provider_require_prompt_file`. Reject any other argument count with exit `1`.

2. Support these environment variables:
   - `GEMINI_BIN`, default `gemini`.
   - `GEMINI_MODEL`, no adapter-defined default; add the CLI's model flag only when non-empty.
   - `GEMINI_TIMEOUT`, default `120`, passed through `provider_run_with_timeout`.
   - `GEMINI_TOKEN_LIMIT`, default `200000`, validated as a non-negative integer before every real invocation (equality with the limit is allowed).

3. `E3D_PILOT_CHECK=1`: perform the availability check before argument-count/prompt validation, print a concise line identifying `gemini`, exit `0` if `GEMINI_BIN` is resolvable via the shared availability helper and `2` otherwise, and never execute the binary.

4. For ordinary and dry-run modes, validate argument count, prompt file, and binary availability first (a missing binary exits `2`).

5. `E3D_PILOT_DRY_RUN=1`: print one safely shell-quoted representation of the exact headless command, showing the prompt-file path as stdin redirection or an equivalent file-input mechanism, including the model flag only when `GEMINI_MODEL` is non-empty, without executing the binary, exposing prompt contents, or requiring/inspecting real credentials.

6. Authentication safety — fail closed before every real call unless free personal OAuth is positively confirmed:
   - Factor the check into a shell function whose inputs can be isolated by tests.
   - Resolve the effective Gemini settings location using the CLI-supported home/config override, falling back to the documented settings file under the effective home directory.
   - Read the documented selected-authentication field and accept only the exact documented value representing personal OAuth; reject missing, malformed, unknown, API-key, Vertex AI, Google Cloud, or other selections.
   - Reject non-empty credential/mode variables that can override personal OAuth even when the settings selection says OAuth (Gemini API keys, Google API keys, Vertex selection, application-default credential paths, configured Google Cloud project/location billing context) — a settings selection alone is insufficient if an overriding paid or ambiguous environment variable is present.
   - Print a clear error and exit `1` before executing Gemini CLI on every rejected or ambiguous case. Never unset credentials and continue. Never inspect a developer's real credentials in tests — use an isolated fake home/config fixture.

7. Headless, tool-free execution:
   - Use Gemini CLI's documented non-interactive prompt-input and JSON-output options; add the model flag only when `GEMINI_MODEL` is non-empty; supply the prompt via stdin or an equivalent file-input mechanism so its contents never appear in argv.
   - Use the CLI's documented disable-all-tools mechanism — disabling all built-in, extension, MCP, shell, file, web, and mutation tools, and all automatic approvals. Omitting `--yolo`, omitting an allow-list, relying on confirmation prompts, or instructing the model not to use tools is not sufficient. If the CLI has no enforceable disable-all-tools mode, do not implement a weaker approximation: fail the task and report that this specification cannot be safely satisfied.
   - Never pass `--yolo` or an equivalent permissive mode.
   - Run the invocation through `provider_run_with_timeout` using `GEMINI_TIMEOUT`; capture stdout for JSON validation and the wrapped command's exit status, mapping every nonzero wrapped status (including a timeout) to adapter exit `1`, while retaining useful stderr diagnostics.

8. Parse a successful response with `jq`:
   - Emit only the provider's answer text to stdout — never the enclosing response JSON.
   - Fail with exit `1` for invalid JSON, explicit invocation errors, a tool-call/tool-request result, or missing/empty answer text.
   - Obtain the exact model/version from the response's own structured model field, never from `GEMINI_MODEL` or a family-name default; if multiple distinct models are reported with no single explicit response-model field, treat model as unmeasured.
   - Obtain total tokens from the documented aggregate total when valid; if no aggregate exists, calculate it only from documented, non-overlapping input/output components. Treat missing, malformed, negative, non-integral, or conflicting usage as unmeasured. Never invent a model or token count.
   - Preserve stdout until all validation and token-limit checks pass, so a call that ultimately fails never emits an answer as if it succeeded.

9. Token-limit enforcement and telemetry:
   - If measured total tokens exceed `GEMINI_TOKEN_LIMIT`, print a clear error, emit no answer and no successful usage record, and exit `1`.
   - On a fully measured, positively-confirmed-free-OAuth success, print exactly one newline-terminated stderr line: `e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`, built with `jq`, `cost_usd` the numeric literal `0`.
   - When the answer is valid but exact model or token usage can't be established, print exactly one usage line instead containing `provider:"gemini"` and `unmeasured:true`, omitting `model`, `tokens`, and `cost_usd` entirely (never a fabricated value). Never emit more than one usage line per invocation.

10. Add executable `tests/phase34.sh` using temporary directories, isolated homes/configuration, deterministic stub binaries, and a cleanup trap. No test may require the real Gemini CLI, network access, or real credentials. At minimum, test:
    - Check mode returns `0`, identifies `gemini`, and does not invoke the stub; check mode returns `2` for a missing binary.
    - Dry-run mode prints the headless JSON command, the disable-all-tools configuration, the optional model flag, and prompt-file redirection, without invoking the stub or placing prompt contents in argv.
    - Missing binary during normal execution returns `2`.
    - Personal-OAuth fixtures use only an isolated test home/configuration; a configured API key, Vertex/Google Cloud mode, credential override, missing auth, malformed auth, or non-personal auth selection all return `1` before the stub is invoked.
    - A fully measured successful response emits only the stub's answer on stdout and exactly one usage line with the exact reported model, expected token total, and numeric `cost_usd:0`.
    - Usage exactly at `GEMINI_TOKEN_LIMIT` succeeds; usage above it returns `1` with no answer output and no measured telemetry.
    - Invalid JSON, an explicit-error response, and a tool-request response all return `1` (assert the adapter never treats an attempted tool call as a successful answer).
    - Missing or ambiguous model/usage produces only the unmeasured telemetry shape, never a fabricated model, token count, or cost.
    - A timeout and every other nonzero CLI exit return `1` while retaining useful diagnostics.
    - The generated argv/command is asserted to contain the documented disable-all-tools configuration and no permissive approval option.
    - A one-round, two-provider `bin/e3d-debate` run succeeds when `gemini` is explicitly named in `--providers`, using deterministic stubs for Gemini, the other provider, and the synthesizer — proving Gemini participates with no change required to `bin/e3d-debate` itself.

11. Extend README.md's "Providers and negotiation" section with a concise `gemini` paragraph, modeled on the existing `grok-build` documentation, that: describes Gemini as an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials; states it is absent from `bin/e3d-debate`'s own defaults and every default/recommended `providers.*` configuration; links to Gemini CLI's official installation and personal-OAuth instructions without recommending an API-key or Vertex AI path; documents all four environment variables and their defaults; explains the adapter's rejection of paid/ambiguous authentication, its headless and enforced tool-disabled execution, its timeout/token ceilings, and its exact response-model telemetry when available; links the motivating debate transcript (`docs/debates/2026-09-15-gemini-qwen-provider-addition/transcript.md`); and does not add Gemini to any configuration JSON snippet or recommended provider list.

### Acceptance Criteria

- Only `lib/providers/gemini`, `tests/phase34.sh`, and `README.md` change.
- `lib/providers/gemini` is executable and conforms to the shared provider prompt, availability, dry-run, timeout, output, telemetry, and exit-code (0/1/2) contracts.
- Prompt content never appears in argv.
- Real execution is impossible without positively confirmed personal free OAuth; known paid, ambiguous, or non-personal auth modes fail with exit `1` before the binary runs.
- Real execution uses the CLI's enforceable disable-all-tools mode — never a weaker approximation.
- Successful, fully-measured responses expose only answer text on stdout plus exactly one valid `cost_usd:0` usage line on stderr with the exact reported model and token count; unmeasured cases emit exactly one `unmeasured:true` line instead, never a fabricated value.
- Over-limit, malformed, paid-auth, ambiguous-auth, timeout, CLI-error, explicit-error, and tool-request paths all return `1`; missing binaries return `2`.
- `tests/phase34.sh` proves this behavior, plus explicit two-provider `bin/e3d-debate` participation, entirely through local stubs — no real Gemini CLI, network access, or real credentials.
- README documents Gemini as an opt-in, explicitly-selected, debate-only trial provider and adds it to no default/recommended configuration.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` succeeds.
