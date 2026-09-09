# Optional Read-Only Remote Mirror for Idea Ledger Provenance

## Overview

Add an opt-in remote mirror that sends a repository’s current append-only idea events and materialized idea snapshots to a repository-configured HTTP endpoint. The local `.e3d-pilot` ledger remains the sole source of truth; the feature only publishes outbound snapshots and never reads remote state.

The mirror is disabled when its configuration is absent or explicitly off. An enabled mirror runs after successful publication and can also be invoked directly with `e3d-pilot storage mirror --repo <path>`.

## Goals

- Define and validate an optional `storage.mirror` configuration block.
- Build a predictably ordered, versioned JSON payload from `events.jsonl` and materialized `idea.json` files.
- Send that payload with one authenticated HTTP POST to a repository-agnostic URL.
- Provide an on-demand CLI command with actionable exit status.
- Trigger the mirror after successful normal, resumed, or fleet-target publication.
- Preserve successful publication when the optional automatic mirror fails.
- Document configuration, security behavior, payload semantics, and failure handling.
- Cover disabled, successful, invalid, and failed mirror behavior with regression tests.

## Non-Goals

- Modifying any file under `.e3d-pilot/**`, including this repository’s configuration.
- Reading, importing, reconciling, or restoring ledger state from the remote endpoint.
- Remote transitions, locking, leases, conflict resolution, or write authority.
- Implementing or selecting a particular mirror server or hosting provider.
- Adding background synchronization, retries, queues, scheduling, or incremental uploads.
- Changing idea lifecycle transitions, approval gates, provenance derivation, or local ledger formats.
- Mirroring unrelated run artifacts, worktrees, source files, credentials, or evidence contents.
- Adding support for URL schemes other than HTTP and HTTPS.

## Existing Files

- `bin/e3d-pilot` owns CLI dispatch, configuration loading, and publish-stage orchestration.
- `config.schema.json` defines valid repository configuration.
- `lib/ideas/ledger.sh` defines the local idea workspace and append-only ledger behavior.
- `lib/ideas/materialize.sh` materializes per-idea `idea.json` snapshots.
- `README.md` documents repository configuration and operator workflows.
- `examples/sample-config.json` demonstrates an inactive repository configuration.
- `lib/ideas/mirror.sh` will be added as the isolated snapshot and transport implementation.
- `tests/phase34.sh` will be added for mirror configuration, transport, CLI, and publish-hook regression coverage.

## Shared Constraints

- Change no more than 6 files and remain below 1400 changed lines across all phases.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, or `.e3d-pilot/**`.
- Treat `.e3d-pilot/events.jsonl` as immutable and every `idea.json` as derived, read-only input.
- Do not acquire or alter idea locks and do not append ledger events for mirror attempts.
- Keep the feature absent/off by default so existing repositories make no new network requests.
- Keep the endpoint entirely configuration-driven, with no fixed organization, host, vendor, or path.
- Obtain the API key only from the environment-variable name in configuration. Never store its value in config, the payload, production artifacts, or diagnostic output.
- Use existing Bash, `git`, `jq`, and `curl` dependencies; add no runtime or package dependency.
- Make exactly one request per enabled mirror invocation, with no retry and no redirect following so credentials cannot be forwarded to another host.
- Supply the Authorization header value to curl through a mechanism that does not place the API-key value in process-list-visible arguments (for example, a curl config/header file rather than a literal `-H`/command-line flag value), consistent with how the request body avoids an evaluated shell command string.
- Automatic mirroring is best-effort after publication has succeeded. A mirror error emits a concise warning but cannot retroactively fail or repeat publication.
- Explicit `storage mirror` execution is strict: disabled or invalid configuration, invalid local JSON, a missing credential, curl failure, or non-success HTTP status must produce a nonzero exit.
- Shell diagnostics must not print the API-key value or the complete Authorization header.
- Preserve existing behavior and output for all commands unrelated to storage mirroring.

## Phase 1 - Mirror Configuration, Snapshot, and Transport

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=config.schema.json -->
<!-- pilot:touches=lib/ideas/mirror.sh -->
<!-- pilot:touches=tests/phase34.sh -->
<!-- runner:read=lib/ideas/ledger.sh -->
<!-- runner:read=lib/ideas/materialize.sh -->
<!-- runner:read=config.schema.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Extend `config.schema.json` with an optional strict `storage.mirror` object containing exactly:

   - `enabled`: required boolean.
   - `url`: required non-empty string whose schema-level pattern permits only `http://` or `https://`.
   - `api_key_env`: required environment-variable name matching `^[A-Za-z_][A-Za-z0-9_]*$`.

   Reject unknown properties in `storage` and `storage.mirror` consistently with the schema’s existing strictness. Do not require `storage` or `mirror`, so all existing valid configurations remain valid. Runtime validation remains responsible for URL properties that cannot be expressed reliably by the schema pattern.

2. Add `lib/ideas/mirror.sh` following the repository’s existing shell-library conventions. Expose narrowly scoped functions for:

   - Reading and validating mirror configuration.
   - Building the current payload.
   - Posting the payload.
   - Running the mirror in strict or best-effort mode.

3. Treat an absent `storage.mirror` block or `"enabled": false` as disabled. Disabled automatic use must return successfully without resolving the named credential, examining ledger inputs, creating a snapshot, or invoking curl. Strict on-demand use must report the disabled state and return nonzero without those actions.

4. For an enabled mirror, validate before any network request that:

   - The URL has an exact lowercase `http` or `https` scheme, a non-empty authority, no user information, and no fragment.
   - `api_key_env` is a valid environment-variable name.
   - The named environment variable exists and has a non-empty value.
   - A missing `.e3d-pilot/events.jsonl` can be represented as an empty event stream; any existing path must be a readable regular file.
   - Every nonblank event line is valid JSON.
   - Every discovered `.e3d-pilot/ideas/*/idea.json` path is a readable regular file containing valid JSON.

5. Build one JSON request body with this stable top-level contract:

   - `schema_version`: integer `1`.
   - `repository`: an object containing `identifier`.
   - `mirrored_at`: the payload-generation time as a UTC RFC 3339 timestamp.
   - `events`: an array preserving nonblank `events.jsonl` values in file order.
   - `ideas`: an array of materialized `idea.json` values ordered bytewise by idea-directory name under `LC_ALL=C`.

   The payload is deterministically ordered for identical ledger inputs, but its `mirrored_at` value intentionally changes between invocations.

   Derive `repository.identifier` as follows:

   - Read `remote.origin.url` from the target repository when available and non-empty.
   - For network-style origins using `scheme://`, require a non-empty authority and reject the `file` scheme. Remove user information, query, and fragment components while retaining the scheme, host, optional port, and path.
   - For SCP-like origins such as `user@host:path`, remove the `user@` prefix and retain `host:path`.
   - Treat file URLs, authority-less scheme URLs, local filesystem paths, and malformed or empty sanitized origins as unusable.
   - Never include a password, access token, query string, fragment, or local absolute path.
   - If no usable sanitized origin remains, use the repository directory basename.
   - Store the resulting sanitized string directly as `identifier`; do not perform network-dependent canonicalization.

   Do not include the mirror endpoint URL, local absolute paths, the API key, environment contents, evidence file contents, run artifacts, or source files.

6. Send the payload using exactly one curl process and one HTTP request:

   - HTTP `POST` to the configured URL.
   - `Content-Type: application/json`.
   - `Authorization: Bearer <resolved key>`, supplied to curl via a mechanism that keeps the resolved key out of process-list-visible command-line arguments (for example, a temporary curl config/header file), never as a literal `-H` flag value.
   - Request body supplied from a file or standard input, without embedding it in an evaluated shell command string.
   - Redirect following explicitly disabled.
   - Retry count explicitly set to zero.
   - Bounded connection and total request time using fixed documented values.
   - Only HTTP statuses from 200 through 299 treated as success.
   - Response body discarded rather than printed or copied into ledger or run state.

7. Use a temporary payload file with mode `0600` where a file is needed, and a temporary curl config/header file with mode `0600` when used to convey the Authorization value; remove both on success, validation error, curl error, HTTP error, or handled interruption. Do not create persistent mirror state beneath `.e3d-pilot`.

8. Add `tests/phase34.sh` using temporary repositories and a fake `curl` placed on `PATH`; tests must not require network access or real credentials. Cover schema acceptance and rejection, event and idea ordering, timestamp shape, repository-identifier fallback and credential/query/fragment scrubbing, file-URL and local-path fallback without absolute-path disclosure, request method and headers, one-request behavior, timeout/retry/redirect options, disabled no-op behavior, missing credentials, malformed ledger input, HTTP/curl failure, temporary-file cleanup, and absence of secret values from payload, diagnostics, and process arguments.

   The fake curl must verify the Authorization value in-process against the expected value (for example, by reading it from the config/header file or stdin path rather than from its own command-line arguments) and record only a boolean or redacted result. It must not persist the raw key or complete Authorization header in an argument log. Any temporary request-body or header-file capture must be checked for secret absence and removed by the test.

### Acceptance Criteria

- Existing configurations with no `storage` field still validate and make no mirror request.
- A valid disabled or enabled mirror block passes schema validation; malformed URLs, invalid environment-variable names, missing required keys, wrong types, and unknown mirror keys fail schema or runtime validation before transport.
- The generated payload contains every valid event and materialized idea exactly once in the required order.
- Identical ledger inputs produce identical `repository`, `events`, and `ideas` values; only `mirrored_at` may vary.
- Repository identifiers never disclose local absolute paths; unusable local, file-style, authority-less, or malformed origins fall back to the repository basename.
- Invalid local JSON fails before curl is invoked and does not modify ledger data.
- An enabled invocation resolves the configured environment variable and performs exactly one authenticated POST.
- The fake transport confirms that redirects are disabled, retries are zero, request time is bounded, and only 2xx status is accepted.
- No API-key value appears in captured request bodies, process arguments, stdout, stderr, production artifacts, or retained test files.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.

## Phase 2 - CLI, Publish Hook, and Documentation

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=examples/sample-config.json -->
<!-- pilot:touches=tests/phase34.sh -->
<!-- runner:read=lib/ideas/mirror.sh -->
<!-- runner:read=lib/publish/local -->
<!-- runner:read=lib/publish/github -->
<!-- runner:read=README.md -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Source the mirror library from `bin/e3d-pilot` through the same path-resolution approach used for existing libraries.

2. Add the on-demand command:

   ```text
   e3d-pilot storage mirror --repo /path/to/repository
   ```

   Integrate it with existing help, repository resolution, configuration loading, and argument-error conventions. Reject unknown storage subcommands, duplicate `--repo` options, missing option values, and unexpected arguments.

3. Run the on-demand command in strict mode:

   - An absent or disabled mirror reports that mirroring is not enabled and exits nonzero without a network request.
   - Successful upload prints a concise confirmation that does not disclose credentials or the complete payload.
   - Configuration, snapshot, transport, and HTTP failures print an actionable sanitized error and exit nonzero.

4. Define a publication attempt as one invocation of a publish backend for one target. Invoke a shared post-success function exactly once after each publication attempt whose backend has completed successfully and whose required publication state has been recorded.

   Route ordinary implementation publication, `repair-run` publication resumes, and every fleet-target publication through that shared post-success function. A fleet operation therefore may perform one mirror request per successfully published target, but never more than one for the same target’s publication attempt.

5. Do not invoke the automatic mirror:

   - Before publication.
   - When review or verification fails.
   - When publication is skipped.
   - When the publish backend fails.
   - When the mirror is absent or disabled.

6. If automatic mirroring fails after successful publication, emit one sanitized warning for that publication attempt and retain the publish command’s otherwise successful status and artifacts. Do not retry either mirroring or publication, roll publication back, append an idea event, or report the idea as implementation-failed solely because mirroring failed.

7. Extend `tests/phase34.sh` to exercise CLI parsing and the publish hook with faked transport and publication dependencies. Verify:

   - Strict on-demand success and failure exit statuses.
   - Help and invalid-subcommand or invalid-argument behavior.
   - No request for absent or disabled configuration.
   - Exactly one request after one successful ordinary publication attempt.
   - No request after failed or skipped publication.
   - Automatic mirror failure leaves successful publication successful.
   - Resumed publication reaches the shared post-success function exactly once.
   - Each successful fleet target reaches the shared post-success function exactly once, while failed or skipped targets do not.
   - Existing idea lifecycle state, event contents, and event counts are unchanged by every mirror outcome.

8. Add a disabled `storage.mirror` example to `examples/sample-config.json` using a fictional `.example.com` HTTPS URL and only an environment-variable name, never a credential value.

9. Update `README.md` to document:

   - The optional config fields and disabled-by-default behavior.
   - A configuration example and safe environment-variable setup.
   - The on-demand command and its strict disabled/error behavior.
   - The versioned payload contents, ordering, changing timestamp, and repository-identifier sanitization and fallback behavior.
   - Automatic post-publish behavior, including per-target fleet behavior and best-effort failure semantics.
   - The fact that the local ledger remains canonical and remote reads, writes back, reconciliation, locking, and a reference server are outside scope.
   - The endpoint’s repository-agnostic nature and the prohibition on putting credentials directly in config.
   - That enabling the feature for a repository is a separate manual edit by the operator to that repository’s `.e3d-pilot/config.json`; the mirror command itself never performs that edit.

### Acceptance Criteria

- `e3d-pilot storage mirror --repo <repo>` performs one strict upload only when a valid enabled mirror is configured.
- The command’s help and argument failures match existing CLI conventions.
- Each successful publication attempt performs at most one enabled mirror upload after publication state is recorded.
- Failed or skipped publication never invokes the mirror.
- An automatic mirror failure produces one sanitized warning while the already-successful publication remains successful.
- Mirror operations never append events, rewrite ideas, alter approvals, acquire lifecycle locks, or create persistent state.
- README and sample configuration explain how to opt in without modifying any protected path in this repository.
- No documentation or example contains a real endpoint, organization assumption, or API-key value.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
