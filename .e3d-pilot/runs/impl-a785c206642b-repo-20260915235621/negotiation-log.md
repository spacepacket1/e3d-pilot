---
run_id: impl-a785c206642b-repo-20260915235621
---

# Negotiation Log

## Round 1

### Draft Before Round

```text
# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant `gemini` provider adapter for explicit `e3d-debate` trials. The adapter must invoke Gemini CLI headlessly, preserve the repository’s provider exit-code and telemetry conventions, prevent accidental use of paid authentication, enforce timeout and token ceilings, and remain absent from all default provider configurations.

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
- `README.md` documents built-in adapters in “Providers and negotiation.”
- `docs/debates/2026-09-15-gemini-qwen-provider-addition/transcript.md` records the decision and scope for this trial adapter.

## Shared Constraints

- The complete implementation must modify no more than three files and remain comfortably within 1,400 changed lines.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, or `.e3d-pilot/**`.
- Preserve the provider exit-code contract: `0` for success, `1` for an available provider whose invocation or validation fails, and `2` when the configured binary is unavailable.
- The prompt must be accepted only as the required `$1` prompt-file argument and validated with `provider_require_prompt_file`.
- Prompt content must reach Gemini CLI through stdin or an equivalent file-reading mechanism; it must never be expanded into an argv argument.
- Gemini must remain opt-in through explicit adapter naming. Do not alter defaults, configuration examples, schemas, pipeline wiring, or debate synthesizer behavior.
- Never enable Gemini CLI tools or automatic tool approval. Do not pass `--yolo` or an equivalent option.
- Tests must use temporary directories and stub binaries, must not require Gemini CLI installation or network access, and must not read or overwrite a developer’s actual Gemini credentials.
- Keep shell code compatible with the Bash conventions already used by the provider adapters and phase tests.

## Phase 1 - Implement and Document the Gemini Trial Adapter

<!-- runner:model=codex:gpt-5.4-mini -->
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

1. Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and implement the same one-prompt-file command-line contract as the existing adapters.

2. Support these environment variables:

   - `GEMINI_BIN`, defaulting to `gemini`.
   - `GEMINI_MODEL`, with no adapter-defined model default. Add Gemini CLI’s model option only when this value is non-empty.
   - `GEMINI_TIMEOUT`, defaulting to 120 seconds and passed through the shared timeout helper.
   - `GEMINI_TOKEN_LIMIT`, defaulting to 200000 and validated as a non-negative integer before a real invocation.

3. Implement `E3D_PILOT_CHECK=1` before prompt-file validation or any real invocation:

   - Print a concise availability line identifying `gemini`.
   - Exit `0` when `GEMINI_BIN` is resolvable by the shared availability check.
   - Exit `2` when it is not resolvable.
   - Never execute the configured binary in check mode.

4. For ordinary and dry-run modes, validate `$1` with `provider_require_prompt_file`. Detect a missing configured binary and exit `2` consistently with the other adapters.

5. Build a fully non-interactive Gemini CLI command using the CLI’s supported headless interface and JSON output format:

   - Supply the validated prompt file through stdin or a documented file-input equivalent so its contents never appear in argv.
   - Include the model selection flag only when `GEMINI_MODEL` is non-empty.
   - Do not include `--yolo`, tool auto-approval, or any option that grants tool execution.
   - Invoke the command through `provider_run_with_timeout` using `GEMINI_TIMEOUT`.
   - Capture stdout for validation while preserving the wrapped command’s failure status and useful stderr diagnostics.

6. Implement `E3D_PILOT_DRY_RUN=1` after validation and availability checks:

   - Print one shell-readable representation of the exact headless command, including the prompt-file path as stdin redirection or equivalent file input.
   - Reflect an optional `GEMINI_MODEL` value in the printed command.
   - Do not execute the Gemini binary.
   - Quote paths and values safely enough that spaces are represented unambiguously.

7. Fail closed before every real call unless free personal OAuth can be positively identified:

   - Detect Gemini CLI’s persisted personal OAuth selection using its documented settings location and selected authentication type, while respecting the effective home/config location used by the CLI.
   - Reject known paid or potentially billed credential paths, including configured Gemini/Google API keys and Vertex AI or Google Cloud credential mode.
   - If authentication is missing, ambiguous, API-key based, Vertex based, or otherwise not positively identifiable as personal free OAuth, print a clear error and exit `1` without executing Gemini CLI.
   - Do not silently remove paid-credential environment variables and continue, because doing so could select an unintended credential source.
   - Keep the authentication check factored so `tests/phase34.sh` can create an isolated fake home containing a personal-OAuth selection without accessing real credentials.

8. Parse a successful JSON response with `jq`:

   - Emit only the provider’s answer text to stdout, without the enclosing Gemini response JSON.
   - Extract the exact model/version string reported by the response rather than copying `GEMINI_MODEL` or inventing a default.
   - Calculate total tokens from the CLI-reported aggregate token field when present, or from documented reported input/output token components when an aggregate is absent.
   - Treat missing, malformed, negative, non-numeric, or ambiguous token usage as an unmeasured response rather than reporting a fabricated count.
   - Treat a missing exact model/version as unmeasured rather than substituting a family name or requested model.
   - Fail with exit `1` if the response is invalid JSON, lacks usable answer text, or explicitly reports an invocation error.

9. Enforce `GEMINI_TOKEN_LIMIT` after parsing successful CLI output and before reporting success:

   - If measured total usage exceeds the configured ceiling, print a clear limit error to stderr, emit no successful usage record, and exit `1`.
   - Equality with the limit is allowed.
   - Do not truncate output and claim success.

10. On a fully measured, positively confirmed free-OAuth success, print exactly one newline-terminated usage record to stderr in this shape:

    `e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`

    Construct the JSON safely with `jq`; `cost_usd` must be the numeric literal `0`.

11. When the call succeeds but exact model or token data cannot be established, follow the Claude adapter’s unmeasured telemetry convention:

    - Print exactly one valid `e3d_provider_usage` JSON line identifying `provider` as `gemini` and containing `unmeasured:true`.
    - Do not include `cost_usd:0` unless the adapter both confirmed personal free OAuth and has enough structured response data to produce the required measured record.
    - Never emit more than one usage line for a single real invocation.

12. Add executable `tests/phase34.sh` using isolated stub binaries and temporary homes. At minimum, test:

    - Check mode returns `0`, reports availability, and does not invoke an available stub.
    - Check mode returns `2` for a missing binary.
    - Dry-run mode prints the headless JSON command, optional model flag, and prompt-file path without invoking the stub or exposing prompt contents in argv.
    - Missing binary during normal execution returns `2`.
    - A successful measured JSON response returns only the stubbed answer on stdout and exactly one correctly shaped usage line containing `provider:"gemini"`, the exact stubbed model/version, the expected total token count, and numeric `cost_usd:0`.
    - A response exactly at `GEMINI_TOKEN_LIMIT` succeeds.
    - A response over `GEMINI_TOKEN_LIMIT` exits `1` and does not emit a successful measured usage record.
    - Invalid or unusable JSON exits `1`.
    - A configured API key, Vertex/Google Cloud mode, absent auth selection, or non-personal auth selection exits `1` before the stub is invoked.
    - An unmeasured but otherwise successful response uses the unmeasured telemetry shape and never fabricates a model, token count, or zero cost.
    - `bin/e3d-debate` completes a one-round, two-provider debate when `gemini` is explicitly named in `--providers`, using deterministic stubs for every invoked provider and synthesizer. Assert that Gemini participated and that no edit to `bin/e3d-debate` was required.
    - Temporary files and authentication fixtures are removed by a trap.

13. Extend README.md’s “Providers and negotiation” section with a concise `gemini` paragraph modeled on the existing `grok-build` documentation:

    - State that Gemini is an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials.
    - State that it is absent from `bin/e3d-debate` defaults and every default or recommended `providers.*` configuration.
    - Document Gemini CLI installation/authentication by pointing users to the Gemini CLI’s official installation and personal OAuth flow without suggesting an API key or Vertex AI path.
    - Document `GEMINI_BIN`, `GEMINI_MODEL`, `GEMINI_TIMEOUT` with its default, and `GEMINI_TOKEN_LIMIT` with its default.
    - Explain that the adapter refuses paid or ambiguous authentication, runs headlessly without tools, enforces timeout and token ceilings, and reports the exact response model when the CLI supplies it.
    - Link the motivating debate transcript.
    - Do not add Gemini to any configuration JSON snippet or recommended pipeline provider list.

### Acceptance Criteria

- `lib/providers/gemini` is executable and conforms to the shared provider prompt, availability, timeout, output, telemetry, and exit-code contracts.
- Gemini CLI receives prompt content from the prompt file without placing that content on argv.
- Real execution is impossible unless personal free OAuth is positively confirmed, and known paid or ambiguous credential modes fail before the binary runs.
- Successful structured responses expose answer text on stdout and exactly one valid usage line on stderr with the exact reported model, measured tokens, and numeric zero cost.
- Over-limit, malformed, paid-auth, ambiguous-auth, timeout, and CLI-error paths return `1`; missing binaries return `2`.
- `tests/phase34.sh` proves adapter behavior and explicit two-provider `e3d-debate` participation entirely through local stubs.
- README documentation clearly presents Gemini as a debate-only, explicitly selected trial provider and does not imply default pipeline support.
- No files other than `lib/providers/gemini`, `tests/phase34.sh`, and `README.md` are changed.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` succeeds.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, tightly scoped to 3 files, and fully aligned with the repo's existing provider contract, exit-code, and telemetry conventions.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, tightly scoped to 3 files, and fully aligned with the repo's existing provider contract, exit-code, and telemetry conventions.
```

### Reviewer 2: codex

Status: revise

Reason: The draft requires Gemini CLI to run “without tools,” but only forbids auto-approval flags, so the security guarantee and its acceptance test are not concretely defined.

Replacement Spec:

```spec
# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant, explicitly selected `gemini` provider adapter for `e3d-debate`. It must invoke Gemini CLI headlessly, accept prompts through stdin, preserve provider exit-code and telemetry conventions, reject paid or ambiguous authentication, enforce timeout and token ceilings, and never approve or execute Gemini tool calls.

## Scope

Modify exactly these files:

- `lib/providers/gemini`
- `tests/phase34.sh`
- `README.md`

Do not modify defaults, schemas, examples, pipeline wiring, synthesizer behavior, `.e3d-pilot/**`, `bin/e3d-debate`, workflows, or licenses. Do not add another provider or run a historical debate.

The implementation must remain within 1,400 changed lines.

## Provider Contract

Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and accept exactly the required `$1` prompt-file argument.

Use:

- `GEMINI_BIN`, default `gemini`
- `GEMINI_MODEL`, with no adapter-defined default
- `GEMINI_TIMEOUT`, default `120`
- `GEMINI_TOKEN_LIMIT`, default `200000`

Validate the prompt using `provider_require_prompt_file`. Prompt contents must be supplied through stdin or an equivalent file-reading mechanism and must never appear in argv.

Preserve exit codes:

- `0`: success
- `1`: validation, authentication, invocation, timeout, response, or token-limit failure
- `2`: configured binary unavailable

Validate `GEMINI_TOKEN_LIMIT` as a non-negative integer before every real invocation. Equality with the limit is allowed.

## Availability and Dry Run

When `E3D_PILOT_CHECK=1`:

- Perform the check before prompt validation.
- Use the shared availability helper.
- Print a concise line identifying `gemini`.
- Exit `0` if `GEMINI_BIN` is resolvable and `2` otherwise.
- Never execute the binary.

For normal and dry-run modes, validate the prompt and binary first.

When `E3D_PILOT_DRY_RUN=1`:

- Print one safely shell-quoted representation of the exact command.
- Show the prompt-file path as stdin redirection or equivalent file input.
- Include the model option only when `GEMINI_MODEL` is non-empty.
- Do not expose prompt contents or execute the binary.
- Do not require or inspect real credentials.

## Authentication Safety

Before every real invocation, positively establish that Gemini CLI is configured for personal OAuth.

Factor this check into a shell function whose inputs can be isolated by tests. Resolve the effective Gemini settings location according to the CLI-supported home/config override, falling back to the documented settings file under the effective home directory.

The check must:

- Read the documented selected-authentication field.
- Accept only the exact documented value representing personal OAuth.
- Reject missing, malformed, unknown, API-key, Vertex AI, Google Cloud, or other selections.
- Reject non-empty credential or mode variables that can override personal OAuth, including Gemini API keys, Google API keys, Vertex selection, application-default credential paths, or configured Google Cloud project/location billing context.
- Print a clear error and exit `1` before executing Gemini CLI on every rejected or ambiguous case.
- Never unset credentials and continue.
- Never inspect a developer’s real credentials in tests.

A settings selection alone is insufficient if an overriding paid or ambiguous environment variable is present.

## Headless and Tool-Free Execution

Use Gemini CLI’s documented non-interactive prompt-input and JSON-output options. Add its model option only when `GEMINI_MODEL` is non-empty.

The adapter must use the CLI’s documented disable-all-tools mechanism. It is not sufficient merely to omit `--yolo`, omit an allow-list, rely on confirmation prompts, or instruct the model not to use tools.

The resulting invocation must:

- Disable all built-in, extension, MCP, shell, file, web, and mutation tools.
- Disable automatic approvals.
- Never pass `--yolo` or an equivalent permissive mode.
- Run through `provider_run_with_timeout` using `GEMINI_TIMEOUT`.
- Capture stdout for JSON validation.
- Preserve the wrapped command’s failure status and useful stderr diagnostics.

If the supported Gemini CLI interface has no enforceable disable-all-tools mode, do not implement a weaker approximation: fail the task and report that this specification cannot be safely satisfied.

`tests/phase34.sh` must assert that the generated argv contains the documented disable-all-tools configuration and no permissive approval option. It must also exercise a stubbed response representing an attempted tool request and verify that the adapter does not treat it as a successful answer.

## JSON Response Handling

Parse successful output using `jq`.

The adapter must:

- Emit only usable answer text to stdout.
- Fail with exit `1` for invalid JSON, explicit invocation errors, tool-call or tool-request results, or missing/empty answer text.
- Obtain the exact model/version from the response’s structured model statistics, not from `GEMINI_MODEL`.
- Treat multiple distinct reported models as unmeasured unless the CLI supplies one explicit response-model field.
- Obtain total tokens from the documented aggregate total when valid.
- If no aggregate exists, calculate the total only from documented, non-overlapping input and output components.
- Treat missing, malformed, negative, non-integral, conflicting, or ambiguous usage as unmeasured.
- Never invent a model or token count.

Preserve stdout until all validation and token-limit checks pass so failed calls emit no answer as successful output.

## Token Limit and Telemetry

If measured total tokens exceed `GEMINI_TOKEN_LIMIT`, print a clear error, emit no answer and no successful usage record, and exit `1`.

On a fully measured success, emit exactly one newline-terminated stderr line:

`e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`

Construct the JSON with `jq`; `cost_usd` must be numeric `0`.

When answer text is valid but exact model or token usage is unmeasured, emit exactly one valid usage line containing:

- `provider:"gemini"`
- `unmeasured:true`

The unmeasured record must omit model, tokens, and `cost_usd`. Never emit more than one usage line per invocation.

## Tests

Add executable `tests/phase34.sh`. Use temporary directories, isolated homes/configuration, deterministic stub binaries, and a cleanup trap. No test may require Gemini CLI, network access, or real credentials.

At minimum test:

- Available check mode returns `0`, identifies Gemini, and does not invoke the stub.
- Missing-binary check mode returns `2`.
- Dry run shows JSON/headless mode, disable-all-tools configuration, optional model, and prompt redirection without executing the stub or placing prompt contents in argv.
- Normal execution with a missing binary returns `2`.
- Personal-OAuth fixtures use only the isolated test home/configuration.
- API keys, Vertex/Cloud mode, credential overrides, missing auth, malformed auth, and non-personal auth all return `1` before stub execution.
- A measured response emits only the answer on stdout and exactly one usage line with the exact response model, expected token total, and numeric zero cost.
- Usage exactly equal to the limit succeeds.
- Usage above the limit returns `1` without answer output or measured telemetry.
- Invalid, unusable, explicit-error, and tool-request responses return `1`.
- Missing or ambiguous model/usage produces only unmeasured telemetry and fabricates no model, tokens, or cost.
- Timeout and nonzero CLI exit return `1` while retaining useful diagnostics.
- A one-round, two-provider `bin/e3d-debate` run succeeds when `gemini` is explicitly named in `--providers`, using deterministic stubs for Gemini, the other provider, and the synthesizer.
- The debate assertion proves Gemini participated and requires no modification to `bin/e3d-debate`.

## Documentation

Extend README.md’s “Providers and negotiation” section with a concise `gemini` paragraph that:

- Describes Gemini as an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials.
- States that Gemini is absent from debate defaults and all default or recommended `providers.*` configurations.
- Links to official Gemini CLI installation and personal OAuth instructions without recommending API-key or Vertex authentication.
- Documents all four environment variables and defaults.
- Explains rejection of paid or ambiguous authentication.
- Explains headless execution, enforced tool disabling, timeout and token ceilings, and exact response-model telemetry when available.
- Links the motivating debate transcript.
- Does not add Gemini to configuration snippets or recommended provider lists.

## Verification and Acceptance

Run:

`set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done`

Acceptance requires:

- Only the three scoped files change.
- The adapter is executable.
- Prompt contents never appear in argv.
- Real execution is impossible without positively confirmed personal OAuth.
- Real execution uses an enforceable disable-all-tools mode.
- Paid, ambiguous, malformed, timeout, CLI-error, explicit-error, tool-request, and over-limit paths return `1`.
- Missing binaries return `2`.
- Successful output contains only answer text plus exactly one valid stderr usage record.
- Gemini participates only when explicitly selected.
- The complete phase-test suite passes.
```

Raw Response:

```text
---STATUS---
status: revise
reason: The draft requires Gemini CLI to run “without tools,” but only forbids auto-approval flags, so the security guarantee and its acceptance test are not concretely defined.
```spec
# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant, explicitly selected `gemini` provider adapter for `e3d-debate`. It must invoke Gemini CLI headlessly, accept prompts through stdin, preserve provider exit-code and telemetry conventions, reject paid or ambiguous authentication, enforce timeout and token ceilings, and never approve or execute Gemini tool calls.

## Scope

Modify exactly these files:

- `lib/providers/gemini`
- `tests/phase34.sh`
- `README.md`

Do not modify defaults, schemas, examples, pipeline wiring, synthesizer behavior, `.e3d-pilot/**`, `bin/e3d-debate`, workflows, or licenses. Do not add another provider or run a historical debate.

The implementation must remain within 1,400 changed lines.

## Provider Contract

Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and accept exactly the required `$1` prompt-file argument.

Use:

- `GEMINI_BIN`, default `gemini`
- `GEMINI_MODEL`, with no adapter-defined default
- `GEMINI_TIMEOUT`, default `120`
- `GEMINI_TOKEN_LIMIT`, default `200000`

Validate the prompt using `provider_require_prompt_file`. Prompt contents must be supplied through stdin or an equivalent file-reading mechanism and must never appear in argv.

Preserve exit codes:

- `0`: success
- `1`: validation, authentication, invocation, timeout, response, or token-limit failure
- `2`: configured binary unavailable

Validate `GEMINI_TOKEN_LIMIT` as a non-negative integer before every real invocation. Equality with the limit is allowed.

## Availability and Dry Run

When `E3D_PILOT_CHECK=1`:

- Perform the check before prompt validation.
- Use the shared availability helper.
- Print a concise line identifying `gemini`.
- Exit `0` if `GEMINI_BIN` is resolvable and `2` otherwise.
- Never execute the binary.

For normal and dry-run modes, validate the prompt and binary first.

When `E3D_PILOT_DRY_RUN=1`:

- Print one safely shell-quoted representation of the exact command.
- Show the prompt-file path as stdin redirection or equivalent file input.
- Include the model option only when `GEMINI_MODEL` is non-empty.
- Do not expose prompt contents or execute the binary.
- Do not require or inspect real credentials.

## Authentication Safety

Before every real invocation, positively establish that Gemini CLI is configured for personal OAuth.

Factor this check into a shell function whose inputs can be isolated by tests. Resolve the effective Gemini settings location according to the CLI-supported home/config override, falling back to the documented settings file under the effective home directory.

The check must:

- Read the documented selected-authentication field.
- Accept only the exact documented value representing personal OAuth.
- Reject missing, malformed, unknown, API-key, Vertex AI, Google Cloud, or other selections.
- Reject non-empty credential or mode variables that can override personal OAuth, including Gemini API keys, Google API keys, Vertex selection, application-default credential paths, or configured Google Cloud project/location billing context.
- Print a clear error and exit `1` before executing Gemini CLI on every rejected or ambiguous case.
- Never unset credentials and continue.
- Never inspect a developer’s real credentials in tests.

A settings selection alone is insufficient if an overriding paid or ambiguous environment variable is present.

## Headless and Tool-Free Execution

Use Gemini CLI’s documented non-interactive prompt-input and JSON-output options. Add its model option only when `GEMINI_MODEL` is non-empty.

The adapter must use the CLI’s documented disable-all-tools mechanism. It is not sufficient merely to omit `--yolo`, omit an allow-list, rely on confirmation prompts, or instruct the model not to use tools.

The resulting invocation must:

- Disable all built-in, extension, MCP, shell, file, web, and mutation tools.
- Disable automatic approvals.
- Never pass `--yolo` or an equivalent permissive mode.
- Run through `provider_run_with_timeout` using `GEMINI_TIMEOUT`.
- Capture stdout for JSON validation.
- Preserve the wrapped command’s failure status and useful stderr diagnostics.

If the supported Gemini CLI interface has no enforceable disable-all-tools mode, do not implement a weaker approximation: fail the task and report that this specification cannot be safely satisfied.

`tests/phase34.sh` must assert that the generated argv contains the documented disable-all-tools configuration and no permissive approval option. It must also exercise a stubbed response representing an attempted tool request and verify that the adapter does not treat it as a successful answer.

## JSON Response Handling

Parse successful output using `jq`.

The adapter must:

- Emit only usable answer text to stdout.
- Fail with exit `1` for invalid JSON, explicit invocation errors, tool-call or tool-request results, or missing/empty answer text.
- Obtain the exact model/version from the response’s structured model statistics, not from `GEMINI_MODEL`.
- Treat multiple distinct reported models as unmeasured unless the CLI supplies one explicit response-model field.
- Obtain total tokens from the documented aggregate total when valid.
- If no aggregate exists, calculate the total only from documented, non-overlapping input and output components.
- Treat missing, malformed, negative, non-integral, conflicting, or ambiguous usage as unmeasured.
- Never invent a model or token count.

Preserve stdout until all validation and token-limit checks pass so failed calls emit no answer as successful output.

## Token Limit and Telemetry

If measured total tokens exceed `GEMINI_TOKEN_LIMIT`, print a clear error, emit no answer and no successful usage record, and exit `1`.

On a fully measured success, emit exactly one newline-terminated stderr line:

`e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`

Construct the JSON with `jq`; `cost_usd` must be numeric `0`.

When answer text is valid but exact model or token usage is unmeasured, emit exactly one valid usage line containing:

- `provider:"gemini"`
- `unmeasured:true`

The unmeasured record must omit model, tokens, and `cost_usd`. Never emit more than one usage line per invocation.

## Tests

Add executable `tests/phase34.sh`. Use temporary directories, isolated homes/configuration, deterministic stub binaries, and a cleanup trap. No test may require Gemini CLI, network access, or real credentials.

At minimum test:

- Available check mode returns `0`, identifies Gemini, and does not invoke the stub.
- Missing-binary check mode returns `2`.
- Dry run shows JSON/headless mode, disable-all-tools configuration, optional model, and prompt redirection without executing the stub or placing prompt contents in argv.
- Normal execution with a missing binary returns `2`.
- Personal-OAuth fixtures use only the isolated test home/configuration.
- API keys, Vertex/Cloud mode, credential overrides, missing auth, malformed auth, and non-personal auth all return `1` before stub execution.
- A measured response emits only the answer on stdout and exactly one usage line with the exact response model, expected token total, and numeric zero cost.
- Usage exactly equal to the limit succeeds.
- Usage above the limit returns `1` without answer output or measured telemetry.
- Invalid, unusable, explicit-error, and tool-request responses return `1`.
- Missing or ambiguous model/usage produces only unmeasured telemetry and fabricates no model, tokens, or cost.
- Timeout and nonzero CLI exit return `1` while retaining useful diagnostics.
- A one-round, two-provider `bin/e3d-debate` run succeeds when `gemini` is explicitly named in `--providers`, using deterministic stubs for Gemini, the other provider, and the synthesizer.
- The debate assertion proves Gemini participated and requires no modification to `bin/e3d-debate`.

## Documentation

Extend README.md’s “Providers and negotiation” section with a concise `gemini` paragraph that:

- Describes Gemini as an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials.
- States that Gemini is absent from debate defaults and all default or recommended `providers.*` configurations.
- Links to official Gemini CLI installation and personal OAuth instructions without recommending API-key or Vertex authentication.
- Documents all four environment variables and defaults.
- Explains rejection of paid or ambiguous authentication.
- Explains headless execution, enforced tool disabling, timeout and token ceilings, and exact response-model telemetry when available.
- Links the motivating debate transcript.
- Does not add Gemini to configuration snippets or recommended provider lists.

## Verification and Acceptance

Run:

`set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done`

Acceptance requires:

- Only the three scoped files change.
- The adapter is executable.
- Prompt contents never appear in argv.
- Real execution is impossible without positively confirmed personal OAuth.
- Real execution uses an enforceable disable-all-tools mode.
- Paid, ambiguous, malformed, timeout, CLI-error, explicit-error, tool-request, and over-limit paths return `1`.
- Missing binaries return `2`.
- Successful output contains only answer text plus exactly one valid stderr usage record.
- Gemini participates only when explicitly selected.
- The complete phase-test suite passes.
```
```

Round Result: not converged

At least one reviewer requested revision in round 1.

## Round 2

### Draft Before Round

```text
# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant, explicitly selected `gemini` provider adapter for `e3d-debate`. It must invoke Gemini CLI headlessly, accept prompts through stdin, preserve provider exit-code and telemetry conventions, reject paid or ambiguous authentication, enforce timeout and token ceilings, and never approve or execute Gemini tool calls.

## Scope

Modify exactly these files:

- `lib/providers/gemini`
- `tests/phase34.sh`
- `README.md`

Do not modify defaults, schemas, examples, pipeline wiring, synthesizer behavior, `.e3d-pilot/**`, `bin/e3d-debate`, workflows, or licenses. Do not add another provider or run a historical debate.

The implementation must remain within 1,400 changed lines.

## Provider Contract

Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and accept exactly the required `$1` prompt-file argument.

Use:

- `GEMINI_BIN`, default `gemini`
- `GEMINI_MODEL`, with no adapter-defined default
- `GEMINI_TIMEOUT`, default `120`
- `GEMINI_TOKEN_LIMIT`, default `200000`

Validate the prompt using `provider_require_prompt_file`. Prompt contents must be supplied through stdin or an equivalent file-reading mechanism and must never appear in argv.

Preserve exit codes:

- `0`: success
- `1`: validation, authentication, invocation, timeout, response, or token-limit failure
- `2`: configured binary unavailable

Validate `GEMINI_TOKEN_LIMIT` as a non-negative integer before every real invocation. Equality with the limit is allowed.

## Availability and Dry Run

When `E3D_PILOT_CHECK=1`:

- Perform the check before prompt validation.
- Use the shared availability helper.
- Print a concise line identifying `gemini`.
- Exit `0` if `GEMINI_BIN` is resolvable and `2` otherwise.
- Never execute the binary.

For normal and dry-run modes, validate the prompt and binary first.

When `E3D_PILOT_DRY_RUN=1`:

- Print one safely shell-quoted representation of the exact command.
- Show the prompt-file path as stdin redirection or equivalent file input.
- Include the model option only when `GEMINI_MODEL` is non-empty.
- Do not expose prompt contents or execute the binary.
- Do not require or inspect real credentials.

## Authentication Safety

Before every real invocation, positively establish that Gemini CLI is configured for personal OAuth.

Factor this check into a shell function whose inputs can be isolated by tests. Resolve the effective Gemini settings location according to the CLI-supported home/config override, falling back to the documented settings file under the effective home directory.

The check must:

- Read the documented selected-authentication field.
- Accept only the exact documented value representing personal OAuth.
- Reject missing, malformed, unknown, API-key, Vertex AI, Google Cloud, or other selections.
- Reject non-empty credential or mode variables that can override personal OAuth, including Gemini API keys, Google API keys, Vertex selection, application-default credential paths, or configured Google Cloud project/location billing context.
- Print a clear error and exit `1` before executing Gemini CLI on every rejected or ambiguous case.
- Never unset credentials and continue.
- Never inspect a developer’s real credentials in tests.

A settings selection alone is insufficient if an overriding paid or ambiguous environment variable is present.

## Headless and Tool-Free Execution

Use Gemini CLI’s documented non-interactive prompt-input and JSON-output options. Add its model option only when `GEMINI_MODEL` is non-empty.

The adapter must use the CLI’s documented disable-all-tools mechanism. It is not sufficient merely to omit `--yolo`, omit an allow-list, rely on confirmation prompts, or instruct the model not to use tools.

The resulting invocation must:

- Disable all built-in, extension, MCP, shell, file, web, and mutation tools.
- Disable automatic approvals.
- Never pass `--yolo` or an equivalent permissive mode.
- Run through `provider_run_with_timeout` using `GEMINI_TIMEOUT`.
- Capture stdout for JSON validation.
- Preserve the wrapped command’s failure status and useful stderr diagnostics.

If the supported Gemini CLI interface has no enforceable disable-all-tools mode, do not implement a weaker approximation: fail the task and report that this specification cannot be safely satisfied.

`tests/phase34.sh` must assert that the generated argv contains the documented disable-all-tools configuration and no permissive approval option. It must also exercise a stubbed response representing an attempted tool request and verify that the adapter does not treat it as a successful answer.

## JSON Response Handling

Parse successful output using `jq`.

The adapter must:

- Emit only usable answer text to stdout.
- Fail with exit `1` for invalid JSON, explicit invocation errors, tool-call or tool-request results, or missing/empty answer text.
- Obtain the exact model/version from the response’s structured model statistics, not from `GEMINI_MODEL`.
- Treat multiple distinct reported models as unmeasured unless the CLI supplies one explicit response-model field.
- Obtain total tokens from the documented aggregate total when valid.
- If no aggregate exists, calculate the total only from documented, non-overlapping input and output components.
- Treat missing, malformed, negative, non-integral, conflicting, or ambiguous usage as unmeasured.
- Never invent a model or token count.

Preserve stdout until all validation and token-limit checks pass so failed calls emit no answer as successful output.

## Token Limit and Telemetry

If measured total tokens exceed `GEMINI_TOKEN_LIMIT`, print a clear error, emit no answer and no successful usage record, and exit `1`.

On a fully measured success, emit exactly one newline-terminated stderr line:

`e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`

Construct the JSON with `jq`; `cost_usd` must be numeric `0`.

When answer text is valid but exact model or token usage is unmeasured, emit exactly one valid usage line containing:

- `provider:"gemini"`
- `unmeasured:true`

The unmeasured record must omit model, tokens, and `cost_usd`. Never emit more than one usage line per invocation.

## Tests

Add executable `tests/phase34.sh`. Use temporary directories, isolated homes/configuration, deterministic stub binaries, and a cleanup trap. No test may require Gemini CLI, network access, or real credentials.

At minimum test:

- Available check mode returns `0`, identifies Gemini, and does not invoke the stub.
- Missing-binary check mode returns `2`.
- Dry run shows JSON/headless mode, disable-all-tools configuration, optional model, and prompt redirection without executing the stub or placing prompt contents in argv.
- Normal execution with a missing binary returns `2`.
- Personal-OAuth fixtures use only the isolated test home/configuration.
- API keys, Vertex/Cloud mode, credential overrides, missing auth, malformed auth, and non-personal auth all return `1` before stub execution.
- A measured response emits only the answer on stdout and exactly one usage line with the exact response model, expected token total, and numeric zero cost.
- Usage exactly equal to the limit succeeds.
- Usage above the limit returns `1` without answer output or measured telemetry.
- Invalid, unusable, explicit-error, and tool-request responses return `1`.
- Missing or ambiguous model/usage produces only unmeasured telemetry and fabricates no model, tokens, or cost.
- Timeout and nonzero CLI exit return `1` while retaining useful diagnostics.
- A one-round, two-provider `bin/e3d-debate` run succeeds when `gemini` is explicitly named in `--providers`, using deterministic stubs for Gemini, the other provider, and the synthesizer.
- The debate assertion proves Gemini participated and requires no modification to `bin/e3d-debate`.

## Documentation

Extend README.md’s “Providers and negotiation” section with a concise `gemini` paragraph that:

- Describes Gemini as an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials.
- States that Gemini is absent from debate defaults and all default or recommended `providers.*` configurations.
- Links to official Gemini CLI installation and personal OAuth instructions without recommending API-key or Vertex authentication.
- Documents all four environment variables and defaults.
- Explains rejection of paid or ambiguous authentication.
- Explains headless execution, enforced tool disabling, timeout and token ceilings, and exact response-model telemetry when available.
- Links the motivating debate transcript.
- Does not add Gemini to configuration snippets or recommended provider lists.

## Verification and Acceptance

Run:

`set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done`

Acceptance requires:

- Only the three scoped files change.
- The adapter is executable.
- Prompt contents never appear in argv.
- Real execution is impossible without positively confirmed personal OAuth.
- Real execution uses an enforceable disable-all-tools mode.
- Paid, ambiguous, malformed, timeout, CLI-error, explicit-error, tool-request, and over-limit paths return `1`.
- Missing binaries return `2`.
- Successful output contains only answer text plus exactly one valid stderr usage record.
- Gemini participates only when explicitly selected.
- The complete phase-test suite passes.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, keeps exit-code/scope contracts intact, and closes prior gaps (fail-closed auth, mandatory disable-all-tools, unmeasured-telemetry rules, explicit test coverage) without contradiction.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, keeps exit-code/scope contracts intact, and closes prior gaps (fail-closed auth, mandatory disable-all-tools, unmeasured-telemetry rules, explicit test coverage) without contradiction.
```

### Reviewer 2: codex

Status: revise

Reason: The draft conflicts on nonzero Gemini CLI exits: it requires provider exit code 1 but also says to preserve the wrapped command’s failure status.

Replacement Spec:

```spec
# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant, explicitly selected `gemini` provider adapter for `e3d-debate`. It must invoke Gemini CLI headlessly, accept prompts through stdin, preserve provider exit-code and telemetry conventions, reject paid or ambiguous authentication, enforce timeout and token ceilings, and never approve or execute Gemini tool calls.

## Scope

Modify exactly these files:

- `lib/providers/gemini`
- `tests/phase34.sh`
- `README.md`

Do not modify defaults, schemas, examples, pipeline wiring, synthesizer behavior, `.e3d-pilot/**`, `bin/e3d-debate`, workflows, or licenses. Do not add another provider or run a historical debate.

The implementation must remain within 1,400 changed lines.

## Provider Contract

Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and require exactly one positional argument: the prompt-file path. Reject any other argument count with exit `1`.

Use:

- `GEMINI_BIN`, default `gemini`
- `GEMINI_MODEL`, with no adapter-defined default
- `GEMINI_TIMEOUT`, default `120`
- `GEMINI_TOKEN_LIMIT`, default `200000`

Validate the prompt using `provider_require_prompt_file`. Prompt contents must be supplied through stdin or an equivalent file-reading mechanism and must never appear in argv.

The adapter’s externally visible exit codes are:

- `0`: success
- `1`: validation, authentication, invocation, timeout, response, or token-limit failure
- `2`: configured binary unavailable

Validate `GEMINI_TOKEN_LIMIT` as a non-negative integer before every real invocation. Equality with the limit is allowed.

## Availability and Dry Run

When `E3D_PILOT_CHECK=1`:

- Perform the check before argument-count and prompt validation.
- Use the shared availability helper.
- Print a concise line identifying `gemini`.
- Exit `0` if `GEMINI_BIN` is resolvable and `2` otherwise.
- Never execute the binary.

For normal and dry-run modes, validate the argument count, prompt, and binary first.

When `E3D_PILOT_DRY_RUN=1`:

- Print one safely shell-quoted representation of the exact command.
- Show the prompt-file path as stdin redirection or equivalent file input.
- Include the model option only when `GEMINI_MODEL` is non-empty.
- Do not expose prompt contents or execute the binary.
- Do not require or inspect real credentials.

## Authentication Safety

Before every real invocation, positively establish that Gemini CLI is configured for personal OAuth.

Factor this check into a shell function whose inputs can be isolated by tests. Resolve the effective Gemini settings location according to the CLI-supported home/config override, falling back to the documented settings file under the effective home directory.

The check must:

- Read the documented selected-authentication field.
- Accept only the exact documented value representing personal OAuth.
- Reject missing, malformed, unknown, API-key, Vertex AI, Google Cloud, or other selections.
- Reject non-empty credential or mode variables that can override personal OAuth, including Gemini API keys, Google API keys, Vertex selection, application-default credential paths, or configured Google Cloud project/location billing context.
- Print a clear error and exit `1` before executing Gemini CLI on every rejected or ambiguous case.
- Never unset credentials and continue.
- Never inspect a developer’s real credentials in tests.

A settings selection alone is insufficient if an overriding paid or ambiguous environment variable is present.

## Headless and Tool-Free Execution

Use Gemini CLI’s documented non-interactive prompt-input and JSON-output options. Add its model option only when `GEMINI_MODEL` is non-empty.

The adapter must use the CLI’s documented disable-all-tools mechanism. It is not sufficient merely to omit `--yolo`, omit an allow-list, rely on confirmation prompts, or instruct the model not to use tools.

The resulting invocation must:

- Disable all built-in, extension, MCP, shell, file, web, and mutation tools.
- Disable automatic approvals.
- Never pass `--yolo` or an equivalent permissive mode.
- Run through `provider_run_with_timeout` using `GEMINI_TIMEOUT`.
- Capture stdout for JSON validation.
- Capture the wrapped command’s status, map every nonzero wrapped status to adapter exit `1`, and retain useful stderr diagnostics.

If the supported Gemini CLI interface has no enforceable disable-all-tools mode, do not implement a weaker approximation: fail the task and report that this specification cannot be safely satisfied.

`tests/phase34.sh` must assert that the generated argv contains the documented disable-all-tools configuration and no permissive approval option. It must also exercise a stubbed response representing an attempted tool request and verify that the adapter does not treat it as a successful answer.

## JSON Response Handling

Parse successful output using `jq`.

The adapter must:

- Emit only usable answer text to stdout.
- Fail with exit `1` for invalid JSON, explicit invocation errors, tool-call or tool-request results, or missing/empty answer text.
- Obtain the exact model/version from the response’s structured model statistics, not from `GEMINI_MODEL`.
- Treat multiple distinct reported models as unmeasured unless the CLI supplies one explicit response-model field.
- Obtain total tokens from the documented aggregate total when valid.
- If no aggregate exists, calculate the total only from documented, non-overlapping input and output components.
- Treat missing, malformed, negative, non-integral, conflicting, or ambiguous usage as unmeasured.
- Never invent a model or token count.

Preserve stdout until all validation and token-limit checks pass so failed calls emit no answer as successful output.

## Token Limit and Telemetry

If measured total tokens exceed `GEMINI_TOKEN_LIMIT`, print a clear error, emit no answer and no successful usage record, and exit `1`.

On a fully measured success, emit exactly one newline-terminated stderr line:

`e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`

Construct the JSON with `jq`; `cost_usd` must be numeric `0`.

When answer text is valid but exact model or token usage is unmeasured, emit exactly one valid usage line containing:

- `provider:"gemini"`
- `unmeasured:true`

The unmeasured record must omit model, tokens, and `cost_usd`. Never emit more than one usage line per invocation.

## Tests

Add executable `tests/phase34.sh`. Use temporary directories, isolated homes/configuration, deterministic stub binaries, and a cleanup trap. No test may require Gemini CLI, network access, or real credentials.

At minimum test:

- Available check mode returns `0`, identifies Gemini, and does not invoke the stub.
- Missing-binary check mode returns `2`.
- Dry run shows JSON/headless mode, disable-all-tools configuration, optional model, and prompt redirection without executing the stub or placing prompt contents in argv.
- Normal execution with a missing binary returns `2`.
- Personal-OAuth fixtures use only the isolated test home/configuration.
- API keys, Vertex/Cloud mode, credential overrides, missing auth, malformed auth, and non-personal auth all return `1` before stub execution.
- A measured response emits only the answer on stdout and exactly one usage line with the exact response model, expected token total, and numeric zero cost.
- Usage exactly equal to the limit succeeds.
- Usage above the limit returns `1` without answer output or measured telemetry.
- Invalid, unusable, explicit-error, and tool-request responses return `1`.
- Missing or ambiguous model/usage produces only unmeasured telemetry and fabricates no model, tokens, or cost.
- Timeout and every nonzero CLI exit return `1` while retaining useful diagnostics.
- A one-round, two-provider `bin/e3d-debate` run succeeds when `gemini` is explicitly named in `--providers`, using deterministic stubs for Gemini, the other provider, and the synthesizer.
- The debate assertion proves Gemini participated and requires no modification to `bin/e3d-debate`.

## Documentation

Extend README.md’s “Providers and negotiation” section with a concise `gemini` paragraph that:

- Describes Gemini as an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials.
- States that Gemini is absent from debate defaults and all default or recommended `providers.*` configurations.
- Links to official Gemini CLI installation and personal OAuth instructions without recommending API-key or Vertex authentication.
- Documents all four environment variables and defaults.
- Explains rejection of paid or ambiguous authentication.
- Explains headless execution, enforced tool disabling, timeout and token ceilings, and exact response-model telemetry when available.
- Links the motivating debate transcript.
- Does not add Gemini to configuration snippets or recommended provider lists.

## Verification and Acceptance

Run:

`set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done`

Acceptance requires:

- Only the three scoped files change.
- The adapter is executable.
- Prompt contents never appear in argv.
- Real execution is impossible without positively confirmed personal OAuth.
- Real execution uses an enforceable disable-all-tools mode.
- Paid, ambiguous, malformed, timeout, CLI-error, explicit-error, tool-request, and over-limit paths return `1`.
- Missing binaries return `2`.
- Successful output contains only answer text on stdout plus exactly one valid usage record on stderr.
- Gemini participates only when explicitly selected.
- The complete phase-test suite passes.
```

Raw Response:

```text
---STATUS---
status: revise
reason: The draft conflicts on nonzero Gemini CLI exits: it requires provider exit code 1 but also says to preserve the wrapped command’s failure status.
```spec
# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant, explicitly selected `gemini` provider adapter for `e3d-debate`. It must invoke Gemini CLI headlessly, accept prompts through stdin, preserve provider exit-code and telemetry conventions, reject paid or ambiguous authentication, enforce timeout and token ceilings, and never approve or execute Gemini tool calls.

## Scope

Modify exactly these files:

- `lib/providers/gemini`
- `tests/phase34.sh`
- `README.md`

Do not modify defaults, schemas, examples, pipeline wiring, synthesizer behavior, `.e3d-pilot/**`, `bin/e3d-debate`, workflows, or licenses. Do not add another provider or run a historical debate.

The implementation must remain within 1,400 changed lines.

## Provider Contract

Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and require exactly one positional argument: the prompt-file path. Reject any other argument count with exit `1`.

Use:

- `GEMINI_BIN`, default `gemini`
- `GEMINI_MODEL`, with no adapter-defined default
- `GEMINI_TIMEOUT`, default `120`
- `GEMINI_TOKEN_LIMIT`, default `200000`

Validate the prompt using `provider_require_prompt_file`. Prompt contents must be supplied through stdin or an equivalent file-reading mechanism and must never appear in argv.

The adapter’s externally visible exit codes are:

- `0`: success
- `1`: validation, authentication, invocation, timeout, response, or token-limit failure
- `2`: configured binary unavailable

Validate `GEMINI_TOKEN_LIMIT` as a non-negative integer before every real invocation. Equality with the limit is allowed.

## Availability and Dry Run

When `E3D_PILOT_CHECK=1`:

- Perform the check before argument-count and prompt validation.
- Use the shared availability helper.
- Print a concise line identifying `gemini`.
- Exit `0` if `GEMINI_BIN` is resolvable and `2` otherwise.
- Never execute the binary.

For normal and dry-run modes, validate the argument count, prompt, and binary first.

When `E3D_PILOT_DRY_RUN=1`:

- Print one safely shell-quoted representation of the exact command.
- Show the prompt-file path as stdin redirection or equivalent file input.
- Include the model option only when `GEMINI_MODEL` is non-empty.
- Do not expose prompt contents or execute the binary.
- Do not require or inspect real credentials.

## Authentication Safety

Before every real invocation, positively establish that Gemini CLI is configured for personal OAuth.

Factor this check into a shell function whose inputs can be isolated by tests. Resolve the effective Gemini settings location according to the CLI-supported home/config override, falling back to the documented settings file under the effective home directory.

The check must:

- Read the documented selected-authentication field.
- Accept only the exact documented value representing personal OAuth.
- Reject missing, malformed, unknown, API-key, Vertex AI, Google Cloud, or other selections.
- Reject non-empty credential or mode variables that can override personal OAuth, including Gemini API keys, Google API keys, Vertex selection, application-default credential paths, or configured Google Cloud project/location billing context.
- Print a clear error and exit `1` before executing Gemini CLI on every rejected or ambiguous case.
- Never unset credentials and continue.
- Never inspect a developer’s real credentials in tests.

A settings selection alone is insufficient if an overriding paid or ambiguous environment variable is present.

## Headless and Tool-Free Execution

Use Gemini CLI’s documented non-interactive prompt-input and JSON-output options. Add its model option only when `GEMINI_MODEL` is non-empty.

The adapter must use the CLI’s documented disable-all-tools mechanism. It is not sufficient merely to omit `--yolo`, omit an allow-list, rely on confirmation prompts, or instruct the model not to use tools.

The resulting invocation must:

- Disable all built-in, extension, MCP, shell, file, web, and mutation tools.
- Disable automatic approvals.
- Never pass `--yolo` or an equivalent permissive mode.
- Run through `provider_run_with_timeout` using `GEMINI_TIMEOUT`.
- Capture stdout for JSON validation.
- Capture the wrapped command’s status, map every nonzero wrapped status to adapter exit `1`, and retain useful stderr diagnostics.

If the supported Gemini CLI interface has no enforceable disable-all-tools mode, do not implement a weaker approximation: fail the task and report that this specification cannot be safely satisfied.

`tests/phase34.sh` must assert that the generated argv contains the documented disable-all-tools configuration and no permissive approval option. It must also exercise a stubbed response representing an attempted tool request and verify that the adapter does not treat it as a successful answer.

## JSON Response Handling

Parse successful output using `jq`.

The adapter must:

- Emit only usable answer text to stdout.
- Fail with exit `1` for invalid JSON, explicit invocation errors, tool-call or tool-request results, or missing/empty answer text.
- Obtain the exact model/version from the response’s structured model statistics, not from `GEMINI_MODEL`.
- Treat multiple distinct reported models as unmeasured unless the CLI supplies one explicit response-model field.
- Obtain total tokens from the documented aggregate total when valid.
- If no aggregate exists, calculate the total only from documented, non-overlapping input and output components.
- Treat missing, malformed, negative, non-integral, conflicting, or ambiguous usage as unmeasured.
- Never invent a model or token count.

Preserve stdout until all validation and token-limit checks pass so failed calls emit no answer as successful output.

## Token Limit and Telemetry

If measured total tokens exceed `GEMINI_TOKEN_LIMIT`, print a clear error, emit no answer and no successful usage record, and exit `1`.

On a fully measured success, emit exactly one newline-terminated stderr line:

`e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`

Construct the JSON with `jq`; `cost_usd` must be numeric `0`.

When answer text is valid but exact model or token usage is unmeasured, emit exactly one valid usage line containing:

- `provider:"gemini"`
- `unmeasured:true`

The unmeasured record must omit model, tokens, and `cost_usd`. Never emit more than one usage line per invocation.

## Tests

Add executable `tests/phase34.sh`. Use temporary directories, isolated homes/configuration, deterministic stub binaries, and a cleanup trap. No test may require Gemini CLI, network access, or real credentials.

At minimum test:

- Available check mode returns `0`, identifies Gemini, and does not invoke the stub.
- Missing-binary check mode returns `2`.
- Dry run shows JSON/headless mode, disable-all-tools configuration, optional model, and prompt redirection without executing the stub or placing prompt contents in argv.
- Normal execution with a missing binary returns `2`.
- Personal-OAuth fixtures use only the isolated test home/configuration.
- API keys, Vertex/Cloud mode, credential overrides, missing auth, malformed auth, and non-personal auth all return `1` before stub execution.
- A measured response emits only the answer on stdout and exactly one usage line with the exact response model, expected token total, and numeric zero cost.
- Usage exactly equal to the limit succeeds.
- Usage above the limit returns `1` without answer output or measured telemetry.
- Invalid, unusable, explicit-error, and tool-request responses return `1`.
- Missing or ambiguous model/usage produces only unmeasured telemetry and fabricates no model, tokens, or cost.
- Timeout and every nonzero CLI exit return `1` while retaining useful diagnostics.
- A one-round, two-provider `bin/e3d-debate` run succeeds when `gemini` is explicitly named in `--providers`, using deterministic stubs for Gemini, the other provider, and the synthesizer.
- The debate assertion proves Gemini participated and requires no modification to `bin/e3d-debate`.

## Documentation

Extend README.md’s “Providers and negotiation” section with a concise `gemini` paragraph that:

- Describes Gemini as an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials.
- States that Gemini is absent from debate defaults and all default or recommended `providers.*` configurations.
- Links to official Gemini CLI installation and personal OAuth instructions without recommending API-key or Vertex authentication.
- Documents all four environment variables and defaults.
- Explains rejection of paid or ambiguous authentication.
- Explains headless execution, enforced tool disabling, timeout and token ceilings, and exact response-model telemetry when available.
- Links the motivating debate transcript.
- Does not add Gemini to configuration snippets or recommended provider lists.

## Verification and Acceptance

Run:

`set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done`

Acceptance requires:

- Only the three scoped files change.
- The adapter is executable.
- Prompt contents never appear in argv.
- Real execution is impossible without positively confirmed personal OAuth.
- Real execution uses an enforceable disable-all-tools mode.
- Paid, ambiguous, malformed, timeout, CLI-error, explicit-error, tool-request, and over-limit paths return `1`.
- Missing binaries return `2`.
- Successful output contains only answer text on stdout plus exactly one valid usage record on stderr.
- Gemini participates only when explicitly selected.
- The complete phase-test suite passes.
```
```

Round Result: not converged

At least one reviewer requested revision in round 2.

## Final Outcome

Needs human review after 2 rounds; spec-draft.md left in place.
## Round 1

### Draft Before Round

```text
# Opt-In Gemini CLI Provider for e3d-debate

## Overview

Add a contract-compliant, explicitly selected `gemini` provider adapter for `e3d-debate`. It must invoke Gemini CLI headlessly, accept prompts through stdin, preserve provider exit-code and telemetry conventions, reject paid or ambiguous authentication, enforce timeout and token ceilings, and never approve or execute Gemini tool calls.

## Scope

Modify exactly these files:

- `lib/providers/gemini`
- `tests/phase34.sh`
- `README.md`

Do not modify defaults, schemas, examples, pipeline wiring, synthesizer behavior, `.e3d-pilot/**`, `bin/e3d-debate`, workflows, or licenses. Do not add another provider or run a historical debate.

The implementation must remain within 1,400 changed lines.

## Provider Contract

Create executable `lib/providers/gemini`, source `lib/providers/common.sh`, and require exactly one positional argument: the prompt-file path. Reject any other argument count with exit `1`.

Use:

- `GEMINI_BIN`, default `gemini`
- `GEMINI_MODEL`, with no adapter-defined default
- `GEMINI_TIMEOUT`, default `120`
- `GEMINI_TOKEN_LIMIT`, default `200000`

Validate the prompt using `provider_require_prompt_file`. Prompt contents must be supplied through stdin or an equivalent file-reading mechanism and must never appear in argv.

The adapter’s externally visible exit codes are:

- `0`: success
- `1`: validation, authentication, invocation, timeout, response, or token-limit failure
- `2`: configured binary unavailable

Validate `GEMINI_TOKEN_LIMIT` as a non-negative integer before every real invocation. Equality with the limit is allowed.

## Availability and Dry Run

When `E3D_PILOT_CHECK=1`:

- Perform the check before argument-count and prompt validation.
- Use the shared availability helper.
- Print a concise line identifying `gemini`.
- Exit `0` if `GEMINI_BIN` is resolvable and `2` otherwise.
- Never execute the binary.

For normal and dry-run modes, validate the argument count, prompt, and binary first.

When `E3D_PILOT_DRY_RUN=1`:

- Print one safely shell-quoted representation of the exact command.
- Show the prompt-file path as stdin redirection or equivalent file input.
- Include the model option only when `GEMINI_MODEL` is non-empty.
- Do not expose prompt contents or execute the binary.
- Do not require or inspect real credentials.

## Authentication Safety

Before every real invocation, positively establish that Gemini CLI is configured for personal OAuth.

Factor this check into a shell function whose inputs can be isolated by tests. Resolve the effective Gemini settings location according to the CLI-supported home/config override, falling back to the documented settings file under the effective home directory.

The check must:

- Read the documented selected-authentication field.
- Accept only the exact documented value representing personal OAuth.
- Reject missing, malformed, unknown, API-key, Vertex AI, Google Cloud, or other selections.
- Reject non-empty credential or mode variables that can override personal OAuth, including Gemini API keys, Google API keys, Vertex selection, application-default credential paths, or configured Google Cloud project/location billing context.
- Print a clear error and exit `1` before executing Gemini CLI on every rejected or ambiguous case.
- Never unset credentials and continue.
- Never inspect a developer’s real credentials in tests.

A settings selection alone is insufficient if an overriding paid or ambiguous environment variable is present.

## Headless and Tool-Free Execution

Use Gemini CLI’s documented non-interactive prompt-input and JSON-output options. Add its model option only when `GEMINI_MODEL` is non-empty.

The adapter must use the CLI’s documented disable-all-tools mechanism. It is not sufficient merely to omit `--yolo`, omit an allow-list, rely on confirmation prompts, or instruct the model not to use tools.

The resulting invocation must:

- Disable all built-in, extension, MCP, shell, file, web, and mutation tools.
- Disable automatic approvals.
- Never pass `--yolo` or an equivalent permissive mode.
- Run through `provider_run_with_timeout` using `GEMINI_TIMEOUT`.
- Capture stdout for JSON validation.
- Capture the wrapped command’s status, map every nonzero wrapped status to adapter exit `1`, and retain useful stderr diagnostics.

If the supported Gemini CLI interface has no enforceable disable-all-tools mode, do not implement a weaker approximation: fail the task and report that this specification cannot be safely satisfied.

`tests/phase34.sh` must assert that the generated argv contains the documented disable-all-tools configuration and no permissive approval option. It must also exercise a stubbed response representing an attempted tool request and verify that the adapter does not treat it as a successful answer.

## JSON Response Handling

Parse successful output using `jq`.

The adapter must:

- Emit only usable answer text to stdout.
- Fail with exit `1` for invalid JSON, explicit invocation errors, tool-call or tool-request results, or missing/empty answer text.
- Obtain the exact model/version from the response’s structured model statistics, not from `GEMINI_MODEL`.
- Treat multiple distinct reported models as unmeasured unless the CLI supplies one explicit response-model field.
- Obtain total tokens from the documented aggregate total when valid.
- If no aggregate exists, calculate the total only from documented, non-overlapping input and output components.
- Treat missing, malformed, negative, non-integral, conflicting, or ambiguous usage as unmeasured.
- Never invent a model or token count.

Preserve stdout until all validation and token-limit checks pass so failed calls emit no answer as successful output.

## Token Limit and Telemetry

If measured total tokens exceed `GEMINI_TOKEN_LIMIT`, print a clear error, emit no answer and no successful usage record, and exit `1`.

On a fully measured success, emit exactly one newline-terminated stderr line:

`e3d_provider_usage={"provider":"gemini","model":<JSON string>,"tokens":<integer>,"cost_usd":0}`

Construct the JSON with `jq`; `cost_usd` must be numeric `0`.

When answer text is valid but exact model or token usage is unmeasured, emit exactly one valid usage line containing:

- `provider:"gemini"`
- `unmeasured:true`

The unmeasured record must omit model, tokens, and `cost_usd`. Never emit more than one usage line per invocation.

## Tests

Add executable `tests/phase34.sh`. Use temporary directories, isolated homes/configuration, deterministic stub binaries, and a cleanup trap. No test may require Gemini CLI, network access, or real credentials.

At minimum test:

- Available check mode returns `0`, identifies Gemini, and does not invoke the stub.
- Missing-binary check mode returns `2`.
- Dry run shows JSON/headless mode, disable-all-tools configuration, optional model, and prompt redirection without executing the stub or placing prompt contents in argv.
- Normal execution with a missing binary returns `2`.
- Personal-OAuth fixtures use only the isolated test home/configuration.
- API keys, Vertex/Cloud mode, credential overrides, missing auth, malformed auth, and non-personal auth all return `1` before stub execution.
- A measured response emits only the answer on stdout and exactly one usage line with the exact response model, expected token total, and numeric zero cost.
- Usage exactly equal to the limit succeeds.
- Usage above the limit returns `1` without answer output or measured telemetry.
- Invalid, unusable, explicit-error, and tool-request responses return `1`.
- Missing or ambiguous model/usage produces only unmeasured telemetry and fabricates no model, tokens, or cost.
- Timeout and every nonzero CLI exit return `1` while retaining useful diagnostics.
- A one-round, two-provider `bin/e3d-debate` run succeeds when `gemini` is explicitly named in `--providers`, using deterministic stubs for Gemini, the other provider, and the synthesizer.
- The debate assertion proves Gemini participated and requires no modification to `bin/e3d-debate`.

## Documentation

Extend README.md’s “Providers and negotiation” section with a concise `gemini` paragraph that:

- Describes Gemini as an opt-in adapter for explicit `e3d-debate --providers ...gemini...` trials.
- States that Gemini is absent from debate defaults and all default or recommended `providers.*` configurations.
- Links to official Gemini CLI installation and personal OAuth instructions without recommending API-key or Vertex authentication.
- Documents all four environment variables and defaults.
- Explains rejection of paid or ambiguous authentication.
- Explains headless execution, enforced tool disabling, timeout and token ceilings, and exact response-model telemetry when available.
- Links the motivating debate transcript.
- Does not add Gemini to configuration snippets or recommended provider lists.

## Verification and Acceptance

Run:

`set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done`

Acceptance requires:

- Only the three scoped files change.
- The adapter is executable.
- Prompt contents never appear in argv.
- Real execution is impossible without positively confirmed personal OAuth.
- Real execution uses an enforceable disable-all-tools mode.
- Paid, ambiguous, malformed, timeout, CLI-error, explicit-error, tool-request, and over-limit paths return `1`.
- Missing binaries return `2`.
- Successful output contains only answer text on stdout plus exactly one valid usage record on stderr.
- Gemini participates only when explicitly selected.
- The complete phase-test suite passes.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, thoroughly scoped, and pairs each functional requirement (auth safety, tool-disabling, telemetry, token limits) with a corresponding test and acceptance criterion.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, thoroughly scoped, and pairs each functional requirement (auth safety, tool-disabling, telemetry, token limits) with a corresponding test and acceptance criterion.
```

### Reviewer 2: codex

Status: approved

Reason: The draft is internally consistent, security-focused, testable, and sufficiently explicit about scope, failure behavior, telemetry, authentication, tool disabling, and acceptance criteria.

Raw Response:

```text
---STATUS---
status: approved
reason: The draft is internally consistent, security-focused, testable, and sufficiently explicit about scope, failure behavior, telemetry, authentication, tool disabling, and acceptance criteria.
```

## Final Outcome

Converged in round 1.
