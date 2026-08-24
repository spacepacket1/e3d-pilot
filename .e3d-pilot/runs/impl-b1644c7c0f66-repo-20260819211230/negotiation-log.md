---
run_id: impl-b1644c7c0f66-repo-20260819211230
---

# Negotiation Log

## Round 1

### Draft Before Round

```text
# Fleet Ops: Live Instance Health Signals

## Overview

Extend the cross-repository `fleet discover` pass with optional, read-only HTTP health checks for configured production instances. The resulting status summary becomes part of the existing fleet facts document, allowing the current ideation pass to produce concrete operational recommendations alongside product and monetization ideas.

## Goals

- Support an optional `live_instances` array in the fleet discovery configuration.
- Collect one bounded HTTP health observation per configured instance.
- Represent successful, degraded, and failed checks without fabricating data.
- Append live health observations to the existing fleet discovery facts.
- Request operational recommendations only when an instance is degraded or down.
- Preserve the existing daily cadence, pipeline, and approval machinery.
- Leave an uncomplicated extension seam for future social-account collectors.

## Non-Goals

- Social-platform engagement collection.
- Near-real-time alerting or a new monitoring service.
- Authentication, credentialed requests, or secret management.
- Retries, historical uptime tracking, or persistent health metrics.
- Automated remediation, deployment, restart, or rollback actions.
- Changes to single-repository discovery or ideation.
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.

## Existing Files

- `bin/e3d-pilot` contains fleet configuration validation, facts construction, prompt construction, and the `fleet_discover_stage` orchestration.
- `examples/sample-fleet-config.json` demonstrates the existing fleet discovery configuration.
- `README.md` documents cross-repository ideation and its focus-dependent output sections.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`.
- `tests/phase*.sh` are the repository’s phase-oriented shell tests.

## Shared Constraints

- Keep the complete change within five files, approximately 250 changed lines, and never exceed 15 changed files or 400 changed lines.
- Use Bash, `jq`, and `curl`; add no runtime or package dependency.
- Keep the feature read-only. HTTP requests must not contain credentials, mutate remote state, or write response bodies outside test-owned temporary directories.
- Route every outbound health request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`.
- Perform exactly one request attempt per configured instance, with no retry.
- Apply `--max-time 10` and `--max-redirs 1` to every request.
- Never fabricate an HTTP status, latency, or health classification. Report unavailable values and concrete failure reasons explicitly.
- Preserve configured instance order in collector output.
- Treat a failed instance check as collected data rather than a collector process failure.
- Keep `live_instances` optional and retain existing fleet behavior when it is absent or empty, except for the documented empty Live Operations facts section and the unconditional prompt guidance that knows when to omit recommendations.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, or `.git/**`.
- Run the configured repository verification command after the phase.

## Phase 1 - Collect and Surface Live Instance Health

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=examples/sample-fleet-config.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Add executable `lib/ops/collect-fleet-health.sh` with this interface:

   ```text
   collect-fleet-health.sh <fleet-config.json>
   ```

   It must read the supplied JSON file and write only a Markdown fragment to standard output.

2. Accept an optional top-level `live_instances` field containing an array of objects with exactly the required health-check inputs:

   ```json
   {
     "name": "Netdoctor",
     "url": "https://netdoctor.example.com/health"
   }
   ```

   Each `name` and `url` must be a non-empty string. Missing or empty `live_instances` must print exactly:

   ```md
   ### Live Instance Status

   No live instances configured.
   ```

3. Exit nonzero with a clear stderr message when the input file is missing or unreadable, contains invalid JSON, has a non-array `live_instances` value, or contains an entry without a non-empty string `name` and `url`. Do not issue any HTTP request when configuration validation fails.

4. Structure the collector with distinct top-level collection and rendering functions for live instances. Avoid a monolithic loop tied to all possible signal types, so a later ticket can add an independent `social_accounts` dispatch without restructuring live-instance validation or collection.

5. For every valid configured instance, invoke `curl` exactly once using a GET request, discarding the response body and including:

   - redirect following bounded by `--max-redirs 1`;
   - `--max-time 10`;
   - no retry option;
   - output capture sufficient to obtain the final HTTP status when available;
   - no authentication headers, cookies, request body, or state-changing method.

6. Measure elapsed wall-clock time around each request and report integer milliseconds. Use Bash-compatible timing facilities already available in the repository environment; do not add another executable dependency solely for timing.

7. Map successful `curl` results as follows:

   - `healthy`: final HTTP status is 2xx and latency is below 2000 ms;
   - `degraded`: final HTTP status is 2xx and latency is at least 2000 ms, or the final status is 3xx;
   - `down`: final HTTP status is 4xx or 5xx;
   - `down`: any other non-2xx/3xx status, with a specific `unexpected-http-status` reason rather than a fabricated status.

8. Map failed `curl` results from the real curl exit code to these stable reasons:

   - `timeout`;
   - `connection-refused`;
   - `dns-error`;
   - `unknown-error`.

   A failed request must be classified `down`. If curl did not provide a valid HTTP status, render the mapped reason in its place. The collector must continue checking later instances and exit zero after reporting all configured check outcomes.

9. For configured instances, print this deterministic Markdown structure in configuration order:

   ```md
   ### Live Instance Status

   - **<name>** (<url>): <classification> — HTTP <status-or-reason>, <latency>ms
   ```

   Ensure instance names and URLs cannot inject additional Markdown lines: normalize embedded carriage returns and newlines before rendering while retaining the validated logical value for the request URL.

10. Extend `validate_fleet_discover_config` in `bin/e3d-pilot` to accept an absent `live_instances` field and validate the same array and non-empty string requirements when it is present. Match the command’s existing error-reporting style for optional fleet configuration fields.

11. In `fleet_discover_stage`, after the existing repository facts have been written and before the provider prompt is built:

   - append one blank-line-separated `## Live Operations` heading to the facts file;
   - invoke the collector with the resolved fleet configuration path;
   - append its Markdown output to the same facts file;
   - treat malformed configuration or an unexpected collector process failure as a stage failure;
   - allow reported `degraded` and `down` instances without failing the stage.

12. Resolve the collector relative to the installed e3d-pilot source tree, consistent with existing helper-script invocation in `bin/e3d-pilot`, so the command works when launched from another working directory.

13. Extend `build_fleet_discover_prompt` with an unconditional instruction governing a possible `### Operational Recommendations` section:

   - create one recommendation for every `degraded` or `down` entry in the Live Operations facts;
   - name the specific instance and observed classification;
   - preserve the reported status or failure reason;
   - give one concrete diagnostic or recovery next step grounded in that observation;
   - omit the entire section when all configured instances are healthy or no instances are configured;
   - never invent an instance, status, latency, cause, or recommendation entry.

14. Add `examples/sample-fleet-config-with-ops.json` alongside the existing example. Preserve the existing provider configuration shape and add several clearly fictional `.example.com` live instances. Do not place real production endpoints or credentials in the example.

15. Update the existing README fleet-discovery documentation to describe:

   - the optional `live_instances` array and its `name`/`url` fields;
   - the bounded, read-only nature and daily cadence of checks;
   - the Live Operations facts section;
   - when `### Operational Recommendations` is emitted or omitted;
   - the new operations example configuration;
   - social engagement signals as a planned follow-on that is not implemented here.

16. Add `tests/phase24.sh` using the established fake-executable-on-`PATH` convention. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network.

17. Keep changes focused on this feature. Do not alter existing scoring, ranking, ledger materialization, focus selection, single-repository stages, or provider dispatch behavior.

### Acceptance Criteria

- `tests/phase24.sh` supplies a fake `curl` earlier on `PATH`, records every invocation, and fails if the collector bypasses that stub.
- Fixture responses cover a fast 2xx result, a 2xx result at or above 2000 ms, a final 3xx result, a 500 result, a timeout, connection refusal, DNS failure, and an unknown curl failure.
- Collector output for those fixtures exactly matches the required heading, ordering, classifications, statuses or reasons, and integer latency formatting.
- The fake-curl trace proves one invocation per configured instance, no retries, and the presence of `--max-time 10` and `--max-redirs 1`.
- A missing or empty `live_instances` field prints the exact “No live instances configured.” fragment and exits zero without invoking curl.
- Invalid JSON, a non-array `live_instances`, an entry missing either required field, and an empty or non-string required field each fail clearly before any curl invocation.
- A failed check does not stop later configured instances from being checked and does not make the collector exit nonzero.
- A fixture containing newline characters in a name or URL cannot inject additional Markdown list items or headings.
- Fleet config validation accepts valid absent, empty, and populated `live_instances` configurations and rejects every malformed shape covered above.
- A stubbed `fleet discover` run with no live instances adds the empty `## Live Operations` facts section while preserving the pre-existing portfolio facts content and ordering.
- A stubbed `fleet discover` run with a down instance includes its rendered observation in the facts file and includes prompt instructions for `### Operational Recommendations`.
- Prompt tests confirm recommendations are required only for degraded or down facts and that the model is explicitly told to omit the entire section for healthy-only or unconfigured facts.
- The README and operations example agree with the implemented configuration and output formats.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
- The final diff touches no more than the five declared files, remains below 400 changed lines, and modifies no protected path.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, respects the five-file/400-line budget, and requirements/acceptance criteria align with goals, non-goals, and shared constraints.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, respects the five-file/400-line budget, and requirements/acceptance criteria align with goals, non-goals, and shared constraints.
```

### Reviewer 2: codex

Status: revise

Reason: The draft needs deterministic latency semantics and stronger URL/curl constraints to prevent option, protocol, redirect, and credential injection.

Replacement Spec:

```spec
# Fleet Ops: Live Instance Health Signals

## Overview

Extend the cross-repository `fleet discover` pass with optional, read-only HTTP health checks for configured production instances. The resulting status summary becomes part of the existing fleet facts document, allowing the current ideation pass to produce concrete operational recommendations alongside product and monetization ideas.

## Goals

- Support an optional `live_instances` array in the fleet discovery configuration.
- Collect one bounded HTTP health observation per configured instance.
- Represent successful, degraded, and failed checks without fabricating data.
- Append live health observations to the existing fleet discovery facts.
- Request operational recommendations only when an instance is degraded or down.
- Preserve the existing daily cadence, pipeline, and approval machinery.
- Leave an uncomplicated extension seam for future social-account collectors.

## Non-Goals

- Social-platform engagement collection.
- Near-real-time alerting or a new monitoring service.
- Authentication, credentialed requests, or secret management.
- Retries, historical uptime tracking, or persistent health metrics.
- Automated remediation, deployment, restart, or rollback actions.
- Changes to single-repository discovery or ideation.
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.

## Existing Files

- `bin/e3d-pilot` contains fleet configuration validation, facts construction, prompt construction, and the `fleet_discover_stage` orchestration.
- `examples/sample-fleet-config.json` demonstrates the existing fleet discovery configuration.
- `README.md` documents cross-repository ideation and its focus-dependent output sections.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`.
- `tests/phase*.sh` are the repository’s phase-oriented shell tests.

## Shared Constraints

- Keep the complete change within five files, approximately 250 changed lines, and never exceed 15 changed files or 400 changed lines.
- Use Bash, `jq`, and `curl`; add no runtime or package dependency.
- Keep the feature read-only. HTTP requests must not contain credentials, mutate remote state, or write response bodies outside test-owned temporary directories.
- Route every outbound health request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`.
- Perform exactly one request attempt per configured instance, with no retry.
- Apply `--max-time 10` and `--max-redirs 1` to every request.
- Restrict initial and redirected requests to HTTP and HTTPS.
- Never fabricate an HTTP status, latency, or health classification. Report unavailable values and concrete failure reasons explicitly.
- Preserve configured instance order in collector output.
- Treat a failed instance check as collected data rather than a collector process failure.
- Keep `live_instances` optional and retain existing fleet behavior when it is absent or empty, except for the documented empty Live Operations facts section and the unconditional prompt guidance that knows when to omit recommendations.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, or `.git/**`.
- Run the configured repository verification command after the phase.

## Phase 1 - Collect and Surface Live Instance Health

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=examples/sample-fleet-config.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Add executable `lib/ops/collect-fleet-health.sh` with this interface:

   ```text
   collect-fleet-health.sh <fleet-config.json>
   ```

   It must read the supplied JSON file and write only a Markdown fragment to standard output.

2. Accept an optional top-level `live_instances` field containing an array of objects with exactly two fields:

   ```json
   {
     "name": "Netdoctor",
     "url": "https://netdoctor.example.com/health"
   }
   ```

   Each `name` and `url` must be a non-empty string, and entries containing missing or additional fields are invalid. The URL must begin with `http://` or `https://`, matched case-insensitively, and must not contain URL userinfo such as `user@host` or `user:password@host`. Missing or empty `live_instances` must print exactly:

   ```md
   ### Live Instance Status

   No live instances configured.
   ```

3. Exit nonzero with a clear stderr message when the input file is missing or unreadable, contains invalid JSON, has a non-array `live_instances` value, or contains an invalid entry under requirement 2. Do not issue any HTTP request when configuration validation fails.

4. Structure the collector with distinct top-level validation, collection, and rendering functions for live instances. Avoid a monolithic loop tied to all possible signal types, so a later ticket can add an independent `social_accounts` dispatch without restructuring live-instance validation or collection.

5. For every valid configured instance, invoke `curl` exactly once using a GET request, discarding the response body and including:

   - redirect following bounded by `--max-redirs 1`;
   - `--max-time 10`;
   - explicit initial-URL and redirect protocol restrictions allowing only HTTP and HTTPS;
   - no retry option;
   - output capture sufficient to obtain the final HTTP status and curl-reported total request time;
   - no authentication headers, cookies, request body, credential options, or state-changing method;
   - `--` immediately before the URL so a configured URL cannot be interpreted as a curl option.

6. Use curl’s `time_total` write-out value as the elapsed request time. Convert it deterministically to integer milliseconds by truncating, not rounding, digits beyond the third decimal place. Perform the conversion in Bash without adding another executable dependency solely for timing. Use the unrounded curl duration when deciding whether the 2000 ms threshold was reached, so a duration at or above exactly 2.000000 seconds is degraded and a lower duration is healthy.

7. Map successful `curl` results as follows:

   - `healthy`: final HTTP status is 2xx and total time is below 2.000000 seconds;
   - `degraded`: final HTTP status is 2xx and total time is at least 2.000000 seconds, or the final status is 3xx;
   - `down`: final HTTP status is 4xx or 5xx;
   - `down`: any other status, with `unexpected-http-status` rendered instead of treating that status as a recognized HTTP result.

   A valid final HTTP status for this feature is a three-digit integer from 100 through 599.

8. Map nonzero curl exit codes to these stable reasons:

   - exit code 28: `timeout`;
   - exit code 7: `connection-refused`;
   - exit code 6: `dns-error`;
   - every other nonzero exit code: `unknown-error`.

   A failed request must be classified `down`, and its mapped failure reason must be rendered in place of an HTTP status even if curl emitted a status before failing. The collector must continue checking later instances and exit zero after reporting all configured check outcomes.

9. For configured instances, print this deterministic Markdown structure in configuration order:

   ```md
   ### Live Instance Status

   - **<name>** (<url>): <classification> — HTTP <status-or-reason>, <latency>ms
   ```

   Normalize embedded carriage returns and newlines in rendered names and URLs to single spaces so they cannot inject additional Markdown lines. Preserve the original validated URL string when passing it to curl. For a failed curl invocation, report the curl-provided elapsed time when it is syntactically valid; otherwise render `unavailable` in place of the latency, producing `unavailablems` under the fixed structure above. Tests must exercise and document this fallback.

10. Extend `validate_fleet_discover_config` in `bin/e3d-pilot` to accept an absent `live_instances` field and enforce the same array, exact-entry-shape, non-empty string, HTTP(S) scheme, and no-userinfo requirements when it is present. Match the command’s existing error-reporting style for optional fleet configuration fields.

11. In `fleet_discover_stage`, after the existing repository facts have been written and before the provider prompt is built:

   - append one blank-line-separated `## Live Operations` heading to the facts file;
   - invoke the collector with the resolved fleet configuration path;
   - append its Markdown output to the same facts file;
   - treat malformed configuration or an unexpected collector process failure as a stage failure;
   - allow reported `degraded` and `down` instances without failing the stage.

12. Resolve the collector relative to the installed e3d-pilot source tree, consistent with existing helper-script invocation in `bin/e3d-pilot`, so the command works when launched from another working directory.

13. Extend `build_fleet_discover_prompt` with an unconditional instruction governing a possible `### Operational Recommendations` section:

   - create one recommendation for every `degraded` or `down` entry in the Live Operations facts;
   - name the specific instance and observed classification;
   - preserve the reported status or failure reason;
   - give one concrete diagnostic or recovery next step grounded in that observation;
   - omit the entire section when all configured instances are healthy or no instances are configured;
   - never invent an instance, status, latency, cause, or recommendation entry.

14. Add `examples/sample-fleet-config-with-ops.json` alongside the existing example. Preserve the existing provider configuration shape and add several clearly fictional `.example.com` live instances. Do not place real production endpoints or credentials in the example.

15. Update the existing README fleet-discovery documentation to describe:

   - the optional `live_instances` array and its `name`/`url` fields;
   - the HTTP(S)-only, bounded, unauthenticated, read-only nature and daily cadence of checks;
   - the Live Operations facts section;
   - when `### Operational Recommendations` is emitted or omitted;
   - the new operations example configuration;
   - social engagement signals as a planned follow-on that is not implemented here.

16. Add `tests/phase24.sh` using the established fake-executable-on-`PATH` convention. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network.

17. Keep changes focused on this feature. Do not alter existing scoring, ranking, ledger materialization, focus selection, single-repository stages, or provider dispatch behavior.

### Acceptance Criteria

- `tests/phase24.sh` supplies a fake `curl` earlier on `PATH`, records every invocation, and fails if the collector bypasses that stub.
- Fixture responses cover a fast 2xx result, a 2xx result at or above 2.000000 seconds, a final 3xx result, a 500 result, a timeout, connection refusal, DNS failure, an unknown curl failure, and a failure with an unavailable or malformed curl timing value.
- Collector output for those fixtures exactly matches the required heading, ordering, classifications, statuses or reasons, deterministic integer latency conversion, and unavailable-latency fallback.
- The fake-curl trace proves one invocation per configured instance, no retries, `--max-time 10`, `--max-redirs 1`, HTTP(S)-only protocol restrictions, and an option terminator immediately before each URL.
- A missing or empty `live_instances` field prints the exact “No live instances configured.” fragment and exits zero without invoking curl.
- Invalid JSON, a non-array `live_instances`, an entry with missing or additional fields, an empty or non-string required field, a non-HTTP(S) URL, and a URL containing userinfo each fail clearly before any curl invocation.
- A failed check renders the mapped failure reason even if the fake curl also emits an HTTP status, does not stop later configured instances from being checked, and does not make the collector exit nonzero.
- A fixture containing escaped carriage-return or newline characters in a name or URL cannot inject additional Markdown list items or headings, while the fake-curl trace proves the original validated URL value was passed as one argument.
- Fleet config validation accepts valid absent, empty, and populated `live_instances` configurations and rejects every malformed shape covered above.
- A stubbed `fleet discover` run with no live instances adds the empty `## Live Operations` facts section while preserving the pre-existing portfolio facts content and ordering.
- A stubbed `fleet discover` run with a down instance includes its rendered observation in the facts file and includes prompt instructions for `### Operational Recommendations`.
- Prompt tests confirm recommendations are required only for degraded or down facts and that the model is explicitly told to omit the entire section for healthy-only or unconfigured facts.
- The README and operations example agree with the implemented configuration and output formats.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
- The final diff touches no more than the five declared files, remains below 400 changed lines, and modifies no protected path.
```

Raw Response:

```text
---STATUS---
status: revise
reason: The draft needs deterministic latency semantics and stronger URL/curl constraints to prevent option, protocol, redirect, and credential injection.
```spec
# Fleet Ops: Live Instance Health Signals

## Overview

Extend the cross-repository `fleet discover` pass with optional, read-only HTTP health checks for configured production instances. The resulting status summary becomes part of the existing fleet facts document, allowing the current ideation pass to produce concrete operational recommendations alongside product and monetization ideas.

## Goals

- Support an optional `live_instances` array in the fleet discovery configuration.
- Collect one bounded HTTP health observation per configured instance.
- Represent successful, degraded, and failed checks without fabricating data.
- Append live health observations to the existing fleet discovery facts.
- Request operational recommendations only when an instance is degraded or down.
- Preserve the existing daily cadence, pipeline, and approval machinery.
- Leave an uncomplicated extension seam for future social-account collectors.

## Non-Goals

- Social-platform engagement collection.
- Near-real-time alerting or a new monitoring service.
- Authentication, credentialed requests, or secret management.
- Retries, historical uptime tracking, or persistent health metrics.
- Automated remediation, deployment, restart, or rollback actions.
- Changes to single-repository discovery or ideation.
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.

## Existing Files

- `bin/e3d-pilot` contains fleet configuration validation, facts construction, prompt construction, and the `fleet_discover_stage` orchestration.
- `examples/sample-fleet-config.json` demonstrates the existing fleet discovery configuration.
- `README.md` documents cross-repository ideation and its focus-dependent output sections.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`.
- `tests/phase*.sh` are the repository’s phase-oriented shell tests.

## Shared Constraints

- Keep the complete change within five files, approximately 250 changed lines, and never exceed 15 changed files or 400 changed lines.
- Use Bash, `jq`, and `curl`; add no runtime or package dependency.
- Keep the feature read-only. HTTP requests must not contain credentials, mutate remote state, or write response bodies outside test-owned temporary directories.
- Route every outbound health request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`.
- Perform exactly one request attempt per configured instance, with no retry.
- Apply `--max-time 10` and `--max-redirs 1` to every request.
- Restrict initial and redirected requests to HTTP and HTTPS.
- Never fabricate an HTTP status, latency, or health classification. Report unavailable values and concrete failure reasons explicitly.
- Preserve configured instance order in collector output.
- Treat a failed instance check as collected data rather than a collector process failure.
- Keep `live_instances` optional and retain existing fleet behavior when it is absent or empty, except for the documented empty Live Operations facts section and the unconditional prompt guidance that knows when to omit recommendations.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, or `.git/**`.
- Run the configured repository verification command after the phase.

## Phase 1 - Collect and Surface Live Instance Health

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=examples/sample-fleet-config.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Add executable `lib/ops/collect-fleet-health.sh` with this interface:

   ```text
   collect-fleet-health.sh <fleet-config.json>
   ```

   It must read the supplied JSON file and write only a Markdown fragment to standard output.

2. Accept an optional top-level `live_instances` field containing an array of objects with exactly two fields:

   ```json
   {
     "name": "Netdoctor",
     "url": "https://netdoctor.example.com/health"
   }
   ```

   Each `name` and `url` must be a non-empty string, and entries containing missing or additional fields are invalid. The URL must begin with `http://` or `https://`, matched case-insensitively, and must not contain URL userinfo such as `user@host` or `user:password@host`. Missing or empty `live_instances` must print exactly:

   ```md
   ### Live Instance Status

   No live instances configured.
   ```

3. Exit nonzero with a clear stderr message when the input file is missing or unreadable, contains invalid JSON, has a non-array `live_instances` value, or contains an invalid entry under requirement 2. Do not issue any HTTP request when configuration validation fails.

4. Structure the collector with distinct top-level validation, collection, and rendering functions for live instances. Avoid a monolithic loop tied to all possible signal types, so a later ticket can add an independent `social_accounts` dispatch without restructuring live-instance validation or collection.

5. For every valid configured instance, invoke `curl` exactly once using a GET request, discarding the response body and including:

   - redirect following bounded by `--max-redirs 1`;
   - `--max-time 10`;
   - explicit initial-URL and redirect protocol restrictions allowing only HTTP and HTTPS;
   - no retry option;
   - output capture sufficient to obtain the final HTTP status and curl-reported total request time;
   - no authentication headers, cookies, request body, credential options, or state-changing method;
   - `--` immediately before the URL so a configured URL cannot be interpreted as a curl option.

6. Use curl’s `time_total` write-out value as the elapsed request time. Convert it deterministically to integer milliseconds by truncating, not rounding, digits beyond the third decimal place. Perform the conversion in Bash without adding another executable dependency solely for timing. Use the unrounded curl duration when deciding whether the 2000 ms threshold was reached, so a duration at or above exactly 2.000000 seconds is degraded and a lower duration is healthy.

7. Map successful `curl` results as follows:

   - `healthy`: final HTTP status is 2xx and total time is below 2.000000 seconds;
   - `degraded`: final HTTP status is 2xx and total time is at least 2.000000 seconds, or the final status is 3xx;
   - `down`: final HTTP status is 4xx or 5xx;
   - `down`: any other status, with `unexpected-http-status` rendered instead of treating that status as a recognized HTTP result.

   A valid final HTTP status for this feature is a three-digit integer from 100 through 599.

8. Map nonzero curl exit codes to these stable reasons:

   - exit code 28: `timeout`;
   - exit code 7: `connection-refused`;
   - exit code 6: `dns-error`;
   - every other nonzero exit code: `unknown-error`.

   A failed request must be classified `down`, and its mapped failure reason must be rendered in place of an HTTP status even if curl emitted a status before failing. The collector must continue checking later instances and exit zero after reporting all configured check outcomes.

9. For configured instances, print this deterministic Markdown structure in configuration order:

   ```md
   ### Live Instance Status

   - **<name>** (<url>): <classification> — HTTP <status-or-reason>, <latency>ms
   ```

   Normalize embedded carriage returns and newlines in rendered names and URLs to single spaces so they cannot inject additional Markdown lines. Preserve the original validated URL string when passing it to curl. For a failed curl invocation, report the curl-provided elapsed time when it is syntactically valid; otherwise render `unavailable` in place of the latency, producing `unavailablems` under the fixed structure above. Tests must exercise and document this fallback.

10. Extend `validate_fleet_discover_config` in `bin/e3d-pilot` to accept an absent `live_instances` field and enforce the same array, exact-entry-shape, non-empty string, HTTP(S) scheme, and no-userinfo requirements when it is present. Match the command’s existing error-reporting style for optional fleet configuration fields.

11. In `fleet_discover_stage`, after the existing repository facts have been written and before the provider prompt is built:

   - append one blank-line-separated `## Live Operations` heading to the facts file;
   - invoke the collector with the resolved fleet configuration path;
   - append its Markdown output to the same facts file;
   - treat malformed configuration or an unexpected collector process failure as a stage failure;
   - allow reported `degraded` and `down` instances without failing the stage.

12. Resolve the collector relative to the installed e3d-pilot source tree, consistent with existing helper-script invocation in `bin/e3d-pilot`, so the command works when launched from another working directory.

13. Extend `build_fleet_discover_prompt` with an unconditional instruction governing a possible `### Operational Recommendations` section:

   - create one recommendation for every `degraded` or `down` entry in the Live Operations facts;
   - name the specific instance and observed classification;
   - preserve the reported status or failure reason;
   - give one concrete diagnostic or recovery next step grounded in that observation;
   - omit the entire section when all configured instances are healthy or no instances are configured;
   - never invent an instance, status, latency, cause, or recommendation entry.

14. Add `examples/sample-fleet-config-with-ops.json` alongside the existing example. Preserve the existing provider configuration shape and add several clearly fictional `.example.com` live instances. Do not place real production endpoints or credentials in the example.

15. Update the existing README fleet-discovery documentation to describe:

   - the optional `live_instances` array and its `name`/`url` fields;
   - the HTTP(S)-only, bounded, unauthenticated, read-only nature and daily cadence of checks;
   - the Live Operations facts section;
   - when `### Operational Recommendations` is emitted or omitted;
   - the new operations example configuration;
   - social engagement signals as a planned follow-on that is not implemented here.

16. Add `tests/phase24.sh` using the established fake-executable-on-`PATH` convention. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network.

17. Keep changes focused on this feature. Do not alter existing scoring, ranking, ledger materialization, focus selection, single-repository stages, or provider dispatch behavior.

### Acceptance Criteria

- `tests/phase24.sh` supplies a fake `curl` earlier on `PATH`, records every invocation, and fails if the collector bypasses that stub.
- Fixture responses cover a fast 2xx result, a 2xx result at or above 2.000000 seconds, a final 3xx result, a 500 result, a timeout, connection refusal, DNS failure, an unknown curl failure, and a failure with an unavailable or malformed curl timing value.
- Collector output for those fixtures exactly matches the required heading, ordering, classifications, statuses or reasons, deterministic integer latency conversion, and unavailable-latency fallback.
- The fake-curl trace proves one invocation per configured instance, no retries, `--max-time 10`, `--max-redirs 1`, HTTP(S)-only protocol restrictions, and an option terminator immediately before each URL.
- A missing or empty `live_instances` field prints the exact “No live instances configured.” fragment and exits zero without invoking curl.
- Invalid JSON, a non-array `live_instances`, an entry with missing or additional fields, an empty or non-string required field, a non-HTTP(S) URL, and a URL containing userinfo each fail clearly before any curl invocation.
- A failed check renders the mapped failure reason even if the fake curl also emits an HTTP status, does not stop later configured instances from being checked, and does not make the collector exit nonzero.
- A fixture containing escaped carriage-return or newline characters in a name or URL cannot inject additional Markdown list items or headings, while the fake-curl trace proves the original validated URL value was passed as one argument.
- Fleet config validation accepts valid absent, empty, and populated `live_instances` configurations and rejects every malformed shape covered above.
- A stubbed `fleet discover` run with no live instances adds the empty `## Live Operations` facts section while preserving the pre-existing portfolio facts content and ordering.
- A stubbed `fleet discover` run with a down instance includes its rendered observation in the facts file and includes prompt instructions for `### Operational Recommendations`.
- Prompt tests confirm recommendations are required only for degraded or down facts and that the model is explicitly told to omit the entire section for healthy-only or unconfigured facts.
- The README and operations example agree with the implemented configuration and output formats.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
- The final diff touches no more than the five declared files, remains below 400 changed lines, and modifies no protected path.
```
```

Round Result: not converged

At least one reviewer requested revision in round 1.

## Round 2

### Draft Before Round

```text
# Fleet Ops: Live Instance Health Signals

## Overview

Extend the cross-repository `fleet discover` pass with optional, read-only HTTP health checks for configured production instances. The resulting status summary becomes part of the existing fleet facts document, allowing the current ideation pass to produce concrete operational recommendations alongside product and monetization ideas.

## Goals

- Support an optional `live_instances` array in the fleet discovery configuration.
- Collect one bounded HTTP health observation per configured instance.
- Represent successful, degraded, and failed checks without fabricating data.
- Append live health observations to the existing fleet discovery facts.
- Request operational recommendations only when an instance is degraded or down.
- Preserve the existing daily cadence, pipeline, and approval machinery.
- Leave an uncomplicated extension seam for future social-account collectors.

## Non-Goals

- Social-platform engagement collection.
- Near-real-time alerting or a new monitoring service.
- Authentication, credentialed requests, or secret management.
- Retries, historical uptime tracking, or persistent health metrics.
- Automated remediation, deployment, restart, or rollback actions.
- Changes to single-repository discovery or ideation.
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.

## Existing Files

- `bin/e3d-pilot` contains fleet configuration validation, facts construction, prompt construction, and the `fleet_discover_stage` orchestration.
- `examples/sample-fleet-config.json` demonstrates the existing fleet discovery configuration.
- `README.md` documents cross-repository ideation and its focus-dependent output sections.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`.
- `tests/phase*.sh` are the repository’s phase-oriented shell tests.

## Shared Constraints

- Keep the complete change within five files, approximately 250 changed lines, and never exceed 15 changed files or 400 changed lines.
- Use Bash, `jq`, and `curl`; add no runtime or package dependency.
- Keep the feature read-only. HTTP requests must not contain credentials, mutate remote state, or write response bodies outside test-owned temporary directories.
- Route every outbound health request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`.
- Perform exactly one request attempt per configured instance, with no retry.
- Apply `--max-time 10` and `--max-redirs 1` to every request.
- Restrict initial and redirected requests to HTTP and HTTPS.
- Never fabricate an HTTP status, latency, or health classification. Report unavailable values and concrete failure reasons explicitly.
- Preserve configured instance order in collector output.
- Treat a failed instance check as collected data rather than a collector process failure.
- Keep `live_instances` optional and retain existing fleet behavior when it is absent or empty, except for the documented empty Live Operations facts section and the unconditional prompt guidance that knows when to omit recommendations.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, or `.git/**`.
- Run the configured repository verification command after the phase.

## Phase 1 - Collect and Surface Live Instance Health

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=examples/sample-fleet-config.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Add executable `lib/ops/collect-fleet-health.sh` with this interface:

   ```text
   collect-fleet-health.sh <fleet-config.json>
   ```

   It must read the supplied JSON file and write only a Markdown fragment to standard output.

2. Accept an optional top-level `live_instances` field containing an array of objects with exactly two fields:

   ```json
   {
     "name": "Netdoctor",
     "url": "https://netdoctor.example.com/health"
   }
   ```

   Each `name` and `url` must be a non-empty string, and entries containing missing or additional fields are invalid. The URL must begin with `http://` or `https://`, matched case-insensitively, and must not contain URL userinfo such as `user@host` or `user:password@host`. Missing or empty `live_instances` must print exactly:

   ```md
   ### Live Instance Status

   No live instances configured.
   ```

3. Exit nonzero with a clear stderr message when the input file is missing or unreadable, contains invalid JSON, has a non-array `live_instances` value, or contains an invalid entry under requirement 2. Do not issue any HTTP request when configuration validation fails.

4. Structure the collector with distinct top-level validation, collection, and rendering functions for live instances. Avoid a monolithic loop tied to all possible signal types, so a later ticket can add an independent `social_accounts` dispatch without restructuring live-instance validation or collection.

5. For every valid configured instance, invoke `curl` exactly once using a GET request, discarding the response body and including:

   - redirect following bounded by `--max-redirs 1`;
   - `--max-time 10`;
   - explicit initial-URL and redirect protocol restrictions allowing only HTTP and HTTPS;
   - no retry option;
   - output capture sufficient to obtain the final HTTP status and curl-reported total request time;
   - no authentication headers, cookies, request body, credential options, or state-changing method;
   - `--` immediately before the URL so a configured URL cannot be interpreted as a curl option.

6. Use curl’s `time_total` write-out value as the elapsed request time. Convert it deterministically to integer milliseconds by truncating, not rounding, digits beyond the third decimal place. Perform the conversion in Bash without adding another executable dependency solely for timing. Use the unrounded curl duration when deciding whether the 2000 ms threshold was reached, so a duration at or above exactly 2.000000 seconds is degraded and a lower duration is healthy.

7. Map successful `curl` results as follows:

   - `healthy`: final HTTP status is 2xx and total time is below 2.000000 seconds;
   - `degraded`: final HTTP status is 2xx and total time is at least 2.000000 seconds, or the final status is 3xx;
   - `down`: final HTTP status is 4xx or 5xx;
   - `down`: any other status, with `unexpected-http-status` rendered instead of treating that status as a recognized HTTP result.

   A valid final HTTP status for this feature is a three-digit integer from 100 through 599.

8. Map nonzero curl exit codes to these stable reasons:

   - exit code 28: `timeout`;
   - exit code 7: `connection-refused`;
   - exit code 6: `dns-error`;
   - every other nonzero exit code: `unknown-error`.

   A failed request must be classified `down`, and its mapped failure reason must be rendered in place of an HTTP status even if curl emitted a status before failing. The collector must continue checking later instances and exit zero after reporting all configured check outcomes.

9. For configured instances, print this deterministic Markdown structure in configuration order:

   ```md
   ### Live Instance Status

   - **<name>** (<url>): <classification> — HTTP <status-or-reason>, <latency>ms
   ```

   Normalize embedded carriage returns and newlines in rendered names and URLs to single spaces so they cannot inject additional Markdown lines. Preserve the original validated URL string when passing it to curl. For a failed curl invocation, report the curl-provided elapsed time when it is syntactically valid; otherwise render `unavailable` in place of the latency, producing `unavailablems` under the fixed structure above. Tests must exercise and document this fallback.

10. Extend `validate_fleet_discover_config` in `bin/e3d-pilot` to accept an absent `live_instances` field and enforce the same array, exact-entry-shape, non-empty string, HTTP(S) scheme, and no-userinfo requirements when it is present. Match the command’s existing error-reporting style for optional fleet configuration fields.

11. In `fleet_discover_stage`, after the existing repository facts have been written and before the provider prompt is built:

   - append one blank-line-separated `## Live Operations` heading to the facts file;
   - invoke the collector with the resolved fleet configuration path;
   - append its Markdown output to the same facts file;
   - treat malformed configuration or an unexpected collector process failure as a stage failure;
   - allow reported `degraded` and `down` instances without failing the stage.

12. Resolve the collector relative to the installed e3d-pilot source tree, consistent with existing helper-script invocation in `bin/e3d-pilot`, so the command works when launched from another working directory.

13. Extend `build_fleet_discover_prompt` with an unconditional instruction governing a possible `### Operational Recommendations` section:

   - create one recommendation for every `degraded` or `down` entry in the Live Operations facts;
   - name the specific instance and observed classification;
   - preserve the reported status or failure reason;
   - give one concrete diagnostic or recovery next step grounded in that observation;
   - omit the entire section when all configured instances are healthy or no instances are configured;
   - never invent an instance, status, latency, cause, or recommendation entry.

14. Add `examples/sample-fleet-config-with-ops.json` alongside the existing example. Preserve the existing provider configuration shape and add several clearly fictional `.example.com` live instances. Do not place real production endpoints or credentials in the example.

15. Update the existing README fleet-discovery documentation to describe:

   - the optional `live_instances` array and its `name`/`url` fields;
   - the HTTP(S)-only, bounded, unauthenticated, read-only nature and daily cadence of checks;
   - the Live Operations facts section;
   - when `### Operational Recommendations` is emitted or omitted;
   - the new operations example configuration;
   - social engagement signals as a planned follow-on that is not implemented here.

16. Add `tests/phase24.sh` using the established fake-executable-on-`PATH` convention. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network.

17. Keep changes focused on this feature. Do not alter existing scoring, ranking, ledger materialization, focus selection, single-repository stages, or provider dispatch behavior.

### Acceptance Criteria

- `tests/phase24.sh` supplies a fake `curl` earlier on `PATH`, records every invocation, and fails if the collector bypasses that stub.
- Fixture responses cover a fast 2xx result, a 2xx result at or above 2.000000 seconds, a final 3xx result, a 500 result, a timeout, connection refusal, DNS failure, an unknown curl failure, and a failure with an unavailable or malformed curl timing value.
- Collector output for those fixtures exactly matches the required heading, ordering, classifications, statuses or reasons, deterministic integer latency conversion, and unavailable-latency fallback.
- The fake-curl trace proves one invocation per configured instance, no retries, `--max-time 10`, `--max-redirs 1`, HTTP(S)-only protocol restrictions, and an option terminator immediately before each URL.
- A missing or empty `live_instances` field prints the exact “No live instances configured.” fragment and exits zero without invoking curl.
- Invalid JSON, a non-array `live_instances`, an entry with missing or additional fields, an empty or non-string required field, a non-HTTP(S) URL, and a URL containing userinfo each fail clearly before any curl invocation.
- A failed check renders the mapped failure reason even if the fake curl also emits an HTTP status, does not stop later configured instances from being checked, and does not make the collector exit nonzero.
- A fixture containing escaped carriage-return or newline characters in a name or URL cannot inject additional Markdown list items or headings, while the fake-curl trace proves the original validated URL value was passed as one argument.
- Fleet config validation accepts valid absent, empty, and populated `live_instances` configurations and rejects every malformed shape covered above.
- A stubbed `fleet discover` run with no live instances adds the empty `## Live Operations` facts section while preserving the pre-existing portfolio facts content and ordering.
- A stubbed `fleet discover` run with a down instance includes its rendered observation in the facts file and includes prompt instructions for `### Operational Recommendations`.
- Prompt tests confirm recommendations are required only for degraded or down facts and that the model is explicitly told to omit the entire section for healthy-only or unconfigured facts.
- The README and operations example agree with the implemented configuration and output formats.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
- The final diff touches no more than the five declared files, remains below 400 changed lines, and modifies no protected path.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, exhaustively specifies validation/collection/classification/rendering behavior, and its file/PATH-stub/REPO_ROOT conventions check out against the actual codebase.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, exhaustively specifies validation/collection/classification/rendering behavior, and its file/PATH-stub/REPO_ROOT conventions check out against the actual codebase.
```

### Reviewer 2: codex

Status: revise

Reason: Successful curl calls with missing or malformed time_total are unclassified, so the collector cannot satisfy the no-fabrication rule deterministically.

Replacement Spec:

```spec
# Fleet Ops: Live Instance Health Signals

## Overview

Extend the cross-repository `fleet discover` pass with optional, read-only HTTP health checks for configured production instances. The resulting status summary becomes part of the existing fleet facts document, allowing the current ideation pass to produce concrete operational recommendations alongside product and monetization ideas.

## Goals

- Support an optional `live_instances` array in the fleet discovery configuration.
- Collect one bounded HTTP health observation per configured instance.
- Represent successful, degraded, and failed checks without fabricating data.
- Append live health observations to the existing fleet discovery facts.
- Request operational recommendations only when an instance is degraded or down.
- Preserve the existing daily cadence, pipeline, and approval machinery.
- Leave an uncomplicated extension seam for future social-account collectors.

## Non-Goals

- Social-platform engagement collection.
- Near-real-time alerting or a new monitoring service.
- Authentication, credentialed requests, or secret management.
- Retries, historical uptime tracking, or persistent health metrics.
- Automated remediation, deployment, restart, or rollback actions.
- Changes to single-repository discovery or ideation.
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.

## Existing Files

- `bin/e3d-pilot` contains fleet configuration validation, facts construction, prompt construction, and the `fleet_discover_stage` orchestration.
- `examples/sample-fleet-config.json` demonstrates the existing fleet discovery configuration.
- `README.md` documents cross-repository ideation and its focus-dependent output sections.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`.
- `tests/phase*.sh` are the repository’s phase-oriented shell tests.

## Shared Constraints

- Keep the complete change within five files, approximately 250 changed lines, and never exceed 15 changed files or 400 changed lines.
- Use Bash, `jq`, and `curl`; add no runtime or package dependency.
- Keep the feature read-only. HTTP requests must not contain credentials, mutate remote state, or write response bodies outside test-owned temporary directories.
- Route every outbound health request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`.
- Perform exactly one request attempt per configured instance, with no retry.
- Apply `--max-time 10` and `--max-redirs 1` to every request.
- Restrict initial and redirected requests to HTTP and HTTPS.
- Never fabricate an HTTP status, latency, or health classification. Report unavailable values and concrete failure reasons explicitly.
- Preserve configured instance order in collector output.
- Treat a failed instance check as collected data rather than a collector process failure.
- Keep `live_instances` optional and retain existing fleet behavior when it is absent or empty, except for the documented empty Live Operations facts section and the unconditional prompt guidance that knows when to omit recommendations.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, or `.git/**`.
- Run the configured repository verification command after the phase.

## Phase 1 - Collect and Surface Live Instance Health

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=examples/sample-fleet-config.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Add executable `lib/ops/collect-fleet-health.sh` with this interface:

   ```text
   collect-fleet-health.sh <fleet-config.json>
   ```

   It must read the supplied JSON file and write only a Markdown fragment to standard output.

2. Accept an optional top-level `live_instances` field containing an array of objects with exactly two fields:

   ```json
   {
     "name": "Netdoctor",
     "url": "https://netdoctor.example.com/health"
   }
   ```

   Each `name` and `url` must be a non-empty string, and entries containing missing or additional fields are invalid. The URL must begin with `http://` or `https://`, matched case-insensitively. Its authority component—the characters after the scheme delimiter and before the first `/`, `?`, or `#`—must be non-empty and must not contain `@`, thereby rejecting URL userinfo such as `user@host` or `user:password@host`. Missing or empty `live_instances` must print exactly:

   ```md
   ### Live Instance Status

   No live instances configured.
   ```

3. Exit nonzero with a clear stderr message when the input file is missing or unreadable, contains invalid JSON, has a non-array `live_instances` value, or contains an invalid entry under requirement 2. Do not issue any HTTP request when configuration validation fails.

4. Structure the collector with distinct top-level validation, collection, and rendering functions for live instances. Avoid a monolithic loop tied to all possible signal types, so a later ticket can add an independent `social_accounts` dispatch without restructuring live-instance validation or collection.

5. For every valid configured instance, invoke `curl` exactly once using a GET request, discarding the response body and including:

   - redirect following bounded by `--max-redirs 1`;
   - `--max-time 10`;
   - explicit initial-URL and redirect protocol restrictions allowing only HTTP and HTTPS;
   - no retry option;
   - output capture sufficient to obtain the final HTTP status and curl-reported total request time;
   - no authentication headers, cookies, request body, credential options, or state-changing method;
   - `--` immediately before the URL so a configured URL cannot be interpreted as a curl option.

6. Treat a curl `time_total` value as syntactically valid only when it matches `^[0-9]+([.][0-9]+)?$`. Use the valid value as the elapsed request time and convert it deterministically to integer milliseconds by padding or truncating the fractional portion to exactly three digits, never rounding. Perform the conversion in Bash without adding another executable dependency solely for timing. Use the unrounded value when deciding whether the 2000 ms threshold was reached, so a duration at or above exactly 2.000000 seconds is degraded and a lower duration is healthy.

7. Map zero-exit curl results as follows:

   - `down` with reason `invalid-curl-output` and latency `unavailable` if `time_total` is missing or syntactically invalid, regardless of any emitted HTTP status;
   - `healthy`: final HTTP status is 2xx and valid total time is below 2.000000 seconds;
   - `degraded`: final HTTP status is 2xx and valid total time is at least 2.000000 seconds, or the final status is 3xx;
   - `down`: final HTTP status is 4xx or 5xx;
   - `down`: any other status, with `unexpected-http-status` rendered instead of treating that status as a recognized HTTP result.

   A recognized final HTTP status for this feature is a three-digit integer from 100 through 599. A missing, malformed, or out-of-range status on an otherwise parseable zero-exit result must follow the `unexpected-http-status` rule.

8. Map nonzero curl exit codes to these stable reasons:

   - exit code 28: `timeout`;
   - exit code 7: `connection-refused`;
   - exit code 6: `dns-error`;
   - every other nonzero exit code: `unknown-error`.

   A failed request must be classified `down`, and its mapped failure reason must be rendered in place of an HTTP status even if curl emitted a status before failing. The collector must continue checking later instances and exit zero after reporting all configured check outcomes.

9. For configured instances, print this deterministic Markdown structure in configuration order:

   ```md
   ### Live Instance Status

   - **<name>** (<url>): <classification> — HTTP <status-or-reason>, <latency>ms
   ```

   Normalize embedded carriage returns and newlines in rendered names and URLs to single spaces so they cannot inject additional Markdown lines. Preserve the original validated URL string when passing it to curl. For a nonzero curl invocation, report the curl-provided elapsed time when it is syntactically valid under requirement 6; otherwise render `unavailable` in place of the latency, producing `unavailablems` under the fixed structure above. For a zero-exit invocation with invalid timing output, render `invalid-curl-output` and `unavailablems` as specified in requirement 7.

10. Extend `validate_fleet_discover_config` in `bin/e3d-pilot` to accept an absent `live_instances` field and enforce the same array, exact-entry-shape, non-empty string, HTTP(S) scheme, non-empty authority, and no-userinfo requirements when it is present. Match the command’s existing error-reporting style for optional fleet configuration fields.

11. In `fleet_discover_stage`, after the existing repository facts have been written and before the provider prompt is built:

   - append one blank-line-separated `## Live Operations` heading to the facts file;
   - invoke the collector with the resolved fleet configuration path;
   - append its Markdown output to the same facts file;
   - treat malformed configuration or an unexpected collector process failure as a stage failure;
   - allow reported `degraded` and `down` instances without failing the stage.

12. Resolve the collector relative to the installed e3d-pilot source tree, consistent with existing helper-script invocation in `bin/e3d-pilot`, so the command works when launched from another working directory.

13. Extend `build_fleet_discover_prompt` with an unconditional instruction governing a possible `### Operational Recommendations` section:

   - create one recommendation for every `degraded` or `down` entry in the Live Operations facts;
   - name the specific instance and observed classification;
   - preserve the reported status or failure reason;
   - give one concrete diagnostic or recovery next step grounded in that observation;
   - omit the entire section when all configured instances are healthy or no instances are configured;
   - never invent an instance, status, latency, cause, or recommendation entry.

14. Add `examples/sample-fleet-config-with-ops.json` alongside the existing example. Preserve the existing provider configuration shape and add several clearly fictional `.example.com` live instances. Do not place real production endpoints or credentials in the example.

15. Update the existing README fleet-discovery documentation to describe:

   - the optional `live_instances` array and its `name`/`url` fields;
   - the HTTP(S)-only, bounded, unauthenticated, read-only nature and daily cadence of checks;
   - the Live Operations facts section;
   - when `### Operational Recommendations` is emitted or omitted;
   - the new operations example configuration;
   - social engagement signals as a planned follow-on that is not implemented here.

16. Add `tests/phase24.sh` using the established fake-executable-on-`PATH` convention. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network.

17. Keep changes focused on this feature. Do not alter existing scoring, ranking, ledger materialization, focus selection, single-repository stages, or provider dispatch behavior.

### Acceptance Criteria

- `tests/phase24.sh` supplies a fake `curl` earlier on `PATH`, records every invocation, and fails if the collector bypasses that stub.
- Fixture responses cover a fast 2xx result, a 2xx result at or above 2.000000 seconds, a final 3xx result, a 500 result, a timeout, connection refusal, DNS failure, an unknown curl failure, a nonzero failure with unavailable or malformed curl timing, and a zero-exit result with unavailable or malformed curl timing.
- Collector output for those fixtures exactly matches the required heading, ordering, classifications, statuses or reasons, deterministic integer latency conversion, and unavailable-latency fallback.
- The fake-curl trace proves one invocation per configured instance, no retries, `--max-time 10`, `--max-redirs 1`, HTTP(S)-only protocol restrictions, and an option terminator immediately before each URL.
- A missing or empty `live_instances` field prints the exact “No live instances configured.” fragment and exits zero without invoking curl.
- Invalid JSON, a non-array `live_instances`, an entry with missing or additional fields, an empty or non-string required field, a non-HTTP(S) URL, a URL with an empty authority, and a URL containing userinfo each fail clearly before any curl invocation.
- A failed check renders the mapped failure reason even if the fake curl also emits an HTTP status, does not stop later configured instances from being checked, and does not make the collector exit nonzero.
- A zero-exit check with missing or malformed timing is rendered as `down` with `invalid-curl-output` and `unavailablems`, without fabricating a threshold-based classification.
- A fixture containing escaped carriage-return or newline characters in a name or URL cannot inject additional Markdown list items or headings, while the fake-curl trace proves the original validated URL value was passed as one argument.
- Fleet config validation accepts valid absent, empty, and populated `live_instances` configurations and rejects every malformed shape covered above.
- A stubbed `fleet discover` run with no live instances adds the empty `## Live Operations` facts section while preserving the pre-existing portfolio facts content and ordering.
- A stubbed `fleet discover` run with a down instance includes its rendered observation in the facts file and includes prompt instructions for `### Operational Recommendations`.
- Prompt tests confirm recommendations are required only for degraded or down facts and that the model is explicitly told to omit the entire section for healthy-only or unconfigured facts.
- The README and operations example agree with the implemented configuration and output formats.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
- The final diff touches no more than the five declared files, remains below 400 changed lines, and modifies no protected path.
```

Raw Response:

```text
---STATUS---
status: revise
reason: Successful curl calls with missing or malformed time_total are unclassified, so the collector cannot satisfy the no-fabrication rule deterministically.
```spec
# Fleet Ops: Live Instance Health Signals

## Overview

Extend the cross-repository `fleet discover` pass with optional, read-only HTTP health checks for configured production instances. The resulting status summary becomes part of the existing fleet facts document, allowing the current ideation pass to produce concrete operational recommendations alongside product and monetization ideas.

## Goals

- Support an optional `live_instances` array in the fleet discovery configuration.
- Collect one bounded HTTP health observation per configured instance.
- Represent successful, degraded, and failed checks without fabricating data.
- Append live health observations to the existing fleet discovery facts.
- Request operational recommendations only when an instance is degraded or down.
- Preserve the existing daily cadence, pipeline, and approval machinery.
- Leave an uncomplicated extension seam for future social-account collectors.

## Non-Goals

- Social-platform engagement collection.
- Near-real-time alerting or a new monitoring service.
- Authentication, credentialed requests, or secret management.
- Retries, historical uptime tracking, or persistent health metrics.
- Automated remediation, deployment, restart, or rollback actions.
- Changes to single-repository discovery or ideation.
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.

## Existing Files

- `bin/e3d-pilot` contains fleet configuration validation, facts construction, prompt construction, and the `fleet_discover_stage` orchestration.
- `examples/sample-fleet-config.json` demonstrates the existing fleet discovery configuration.
- `README.md` documents cross-repository ideation and its focus-dependent output sections.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`.
- `tests/phase*.sh` are the repository’s phase-oriented shell tests.

## Shared Constraints

- Keep the complete change within five files, approximately 250 changed lines, and never exceed 15 changed files or 400 changed lines.
- Use Bash, `jq`, and `curl`; add no runtime or package dependency.
- Keep the feature read-only. HTTP requests must not contain credentials, mutate remote state, or write response bodies outside test-owned temporary directories.
- Route every outbound health request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`.
- Perform exactly one request attempt per configured instance, with no retry.
- Apply `--max-time 10` and `--max-redirs 1` to every request.
- Restrict initial and redirected requests to HTTP and HTTPS.
- Never fabricate an HTTP status, latency, or health classification. Report unavailable values and concrete failure reasons explicitly.
- Preserve configured instance order in collector output.
- Treat a failed instance check as collected data rather than a collector process failure.
- Keep `live_instances` optional and retain existing fleet behavior when it is absent or empty, except for the documented empty Live Operations facts section and the unconditional prompt guidance that knows when to omit recommendations.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, or `.git/**`.
- Run the configured repository verification command after the phase.

## Phase 1 - Collect and Surface Live Instance Health

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=examples/sample-fleet-config.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Add executable `lib/ops/collect-fleet-health.sh` with this interface:

   ```text
   collect-fleet-health.sh <fleet-config.json>
   ```

   It must read the supplied JSON file and write only a Markdown fragment to standard output.

2. Accept an optional top-level `live_instances` field containing an array of objects with exactly two fields:

   ```json
   {
     "name": "Netdoctor",
     "url": "https://netdoctor.example.com/health"
   }
   ```

   Each `name` and `url` must be a non-empty string, and entries containing missing or additional fields are invalid. The URL must begin with `http://` or `https://`, matched case-insensitively. Its authority component—the characters after the scheme delimiter and before the first `/`, `?`, or `#`—must be non-empty and must not contain `@`, thereby rejecting URL userinfo such as `user@host` or `user:password@host`. Missing or empty `live_instances` must print exactly:

   ```md
   ### Live Instance Status

   No live instances configured.
   ```

3. Exit nonzero with a clear stderr message when the input file is missing or unreadable, contains invalid JSON, has a non-array `live_instances` value, or contains an invalid entry under requirement 2. Do not issue any HTTP request when configuration validation fails.

4. Structure the collector with distinct top-level validation, collection, and rendering functions for live instances. Avoid a monolithic loop tied to all possible signal types, so a later ticket can add an independent `social_accounts` dispatch without restructuring live-instance validation or collection.

5. For every valid configured instance, invoke `curl` exactly once using a GET request, discarding the response body and including:

   - redirect following bounded by `--max-redirs 1`;
   - `--max-time 10`;
   - explicit initial-URL and redirect protocol restrictions allowing only HTTP and HTTPS;
   - no retry option;
   - output capture sufficient to obtain the final HTTP status and curl-reported total request time;
   - no authentication headers, cookies, request body, credential options, or state-changing method;
   - `--` immediately before the URL so a configured URL cannot be interpreted as a curl option.

6. Treat a curl `time_total` value as syntactically valid only when it matches `^[0-9]+([.][0-9]+)?$`. Use the valid value as the elapsed request time and convert it deterministically to integer milliseconds by padding or truncating the fractional portion to exactly three digits, never rounding. Perform the conversion in Bash without adding another executable dependency solely for timing. Use the unrounded value when deciding whether the 2000 ms threshold was reached, so a duration at or above exactly 2.000000 seconds is degraded and a lower duration is healthy.

7. Map zero-exit curl results as follows:

   - `down` with reason `invalid-curl-output` and latency `unavailable` if `time_total` is missing or syntactically invalid, regardless of any emitted HTTP status;
   - `healthy`: final HTTP status is 2xx and valid total time is below 2.000000 seconds;
   - `degraded`: final HTTP status is 2xx and valid total time is at least 2.000000 seconds, or the final status is 3xx;
   - `down`: final HTTP status is 4xx or 5xx;
   - `down`: any other status, with `unexpected-http-status` rendered instead of treating that status as a recognized HTTP result.

   A recognized final HTTP status for this feature is a three-digit integer from 100 through 599. A missing, malformed, or out-of-range status on an otherwise parseable zero-exit result must follow the `unexpected-http-status` rule.

8. Map nonzero curl exit codes to these stable reasons:

   - exit code 28: `timeout`;
   - exit code 7: `connection-refused`;
   - exit code 6: `dns-error`;
   - every other nonzero exit code: `unknown-error`.

   A failed request must be classified `down`, and its mapped failure reason must be rendered in place of an HTTP status even if curl emitted a status before failing. The collector must continue checking later instances and exit zero after reporting all configured check outcomes.

9. For configured instances, print this deterministic Markdown structure in configuration order:

   ```md
   ### Live Instance Status

   - **<name>** (<url>): <classification> — HTTP <status-or-reason>, <latency>ms
   ```

   Normalize embedded carriage returns and newlines in rendered names and URLs to single spaces so they cannot inject additional Markdown lines. Preserve the original validated URL string when passing it to curl. For a nonzero curl invocation, report the curl-provided elapsed time when it is syntactically valid under requirement 6; otherwise render `unavailable` in place of the latency, producing `unavailablems` under the fixed structure above. For a zero-exit invocation with invalid timing output, render `invalid-curl-output` and `unavailablems` as specified in requirement 7.

10. Extend `validate_fleet_discover_config` in `bin/e3d-pilot` to accept an absent `live_instances` field and enforce the same array, exact-entry-shape, non-empty string, HTTP(S) scheme, non-empty authority, and no-userinfo requirements when it is present. Match the command’s existing error-reporting style for optional fleet configuration fields.

11. In `fleet_discover_stage`, after the existing repository facts have been written and before the provider prompt is built:

   - append one blank-line-separated `## Live Operations` heading to the facts file;
   - invoke the collector with the resolved fleet configuration path;
   - append its Markdown output to the same facts file;
   - treat malformed configuration or an unexpected collector process failure as a stage failure;
   - allow reported `degraded` and `down` instances without failing the stage.

12. Resolve the collector relative to the installed e3d-pilot source tree, consistent with existing helper-script invocation in `bin/e3d-pilot`, so the command works when launched from another working directory.

13. Extend `build_fleet_discover_prompt` with an unconditional instruction governing a possible `### Operational Recommendations` section:

   - create one recommendation for every `degraded` or `down` entry in the Live Operations facts;
   - name the specific instance and observed classification;
   - preserve the reported status or failure reason;
   - give one concrete diagnostic or recovery next step grounded in that observation;
   - omit the entire section when all configured instances are healthy or no instances are configured;
   - never invent an instance, status, latency, cause, or recommendation entry.

14. Add `examples/sample-fleet-config-with-ops.json` alongside the existing example. Preserve the existing provider configuration shape and add several clearly fictional `.example.com` live instances. Do not place real production endpoints or credentials in the example.

15. Update the existing README fleet-discovery documentation to describe:

   - the optional `live_instances` array and its `name`/`url` fields;
   - the HTTP(S)-only, bounded, unauthenticated, read-only nature and daily cadence of checks;
   - the Live Operations facts section;
   - when `### Operational Recommendations` is emitted or omitted;
   - the new operations example configuration;
   - social engagement signals as a planned follow-on that is not implemented here.

16. Add `tests/phase24.sh` using the established fake-executable-on-`PATH` convention. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network.

17. Keep changes focused on this feature. Do not alter existing scoring, ranking, ledger materialization, focus selection, single-repository stages, or provider dispatch behavior.

### Acceptance Criteria

- `tests/phase24.sh` supplies a fake `curl` earlier on `PATH`, records every invocation, and fails if the collector bypasses that stub.
- Fixture responses cover a fast 2xx result, a 2xx result at or above 2.000000 seconds, a final 3xx result, a 500 result, a timeout, connection refusal, DNS failure, an unknown curl failure, a nonzero failure with unavailable or malformed curl timing, and a zero-exit result with unavailable or malformed curl timing.
- Collector output for those fixtures exactly matches the required heading, ordering, classifications, statuses or reasons, deterministic integer latency conversion, and unavailable-latency fallback.
- The fake-curl trace proves one invocation per configured instance, no retries, `--max-time 10`, `--max-redirs 1`, HTTP(S)-only protocol restrictions, and an option terminator immediately before each URL.
- A missing or empty `live_instances` field prints the exact “No live instances configured.” fragment and exits zero without invoking curl.
- Invalid JSON, a non-array `live_instances`, an entry with missing or additional fields, an empty or non-string required field, a non-HTTP(S) URL, a URL with an empty authority, and a URL containing userinfo each fail clearly before any curl invocation.
- A failed check renders the mapped failure reason even if the fake curl also emits an HTTP status, does not stop later configured instances from being checked, and does not make the collector exit nonzero.
- A zero-exit check with missing or malformed timing is rendered as `down` with `invalid-curl-output` and `unavailablems`, without fabricating a threshold-based classification.
- A fixture containing escaped carriage-return or newline characters in a name or URL cannot inject additional Markdown list items or headings, while the fake-curl trace proves the original validated URL value was passed as one argument.
- Fleet config validation accepts valid absent, empty, and populated `live_instances` configurations and rejects every malformed shape covered above.
- A stubbed `fleet discover` run with no live instances adds the empty `## Live Operations` facts section while preserving the pre-existing portfolio facts content and ordering.
- A stubbed `fleet discover` run with a down instance includes its rendered observation in the facts file and includes prompt instructions for `### Operational Recommendations`.
- Prompt tests confirm recommendations are required only for degraded or down facts and that the model is explicitly told to omit the entire section for healthy-only or unconfigured facts.
- The README and operations example agree with the implemented configuration and output formats.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
- The final diff touches no more than the five declared files, remains below 400 changed lines, and modifies no protected path.
```
```

Round Result: not converged

At least one reviewer requested revision in round 2.

## Round 3

### Draft Before Round

```text
# Fleet Ops: Live Instance Health Signals

## Overview

Extend the cross-repository `fleet discover` pass with optional, read-only HTTP health checks for configured production instances. The resulting status summary becomes part of the existing fleet facts document, allowing the current ideation pass to produce concrete operational recommendations alongside product and monetization ideas.

## Goals

- Support an optional `live_instances` array in the fleet discovery configuration.
- Collect one bounded HTTP health observation per configured instance.
- Represent successful, degraded, and failed checks without fabricating data.
- Append live health observations to the existing fleet discovery facts.
- Request operational recommendations only when an instance is degraded or down.
- Preserve the existing daily cadence, pipeline, and approval machinery.
- Leave an uncomplicated extension seam for future social-account collectors.

## Non-Goals

- Social-platform engagement collection.
- Near-real-time alerting or a new monitoring service.
- Authentication, credentialed requests, or secret management.
- Retries, historical uptime tracking, or persistent health metrics.
- Automated remediation, deployment, restart, or rollback actions.
- Changes to single-repository discovery or ideation.
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.

## Existing Files

- `bin/e3d-pilot` contains fleet configuration validation, facts construction, prompt construction, and the `fleet_discover_stage` orchestration.
- `examples/sample-fleet-config.json` demonstrates the existing fleet discovery configuration.
- `README.md` documents cross-repository ideation and its focus-dependent output sections.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`.
- `tests/phase*.sh` are the repository’s phase-oriented shell tests.

## Shared Constraints

- Keep the complete change within five files, approximately 250 changed lines, and never exceed 15 changed files or 400 changed lines.
- Use Bash, `jq`, and `curl`; add no runtime or package dependency.
- Keep the feature read-only. HTTP requests must not contain credentials, mutate remote state, or write response bodies outside test-owned temporary directories.
- Route every outbound health request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`.
- Perform exactly one request attempt per configured instance, with no retry.
- Apply `--max-time 10` and `--max-redirs 1` to every request.
- Restrict initial and redirected requests to HTTP and HTTPS.
- Never fabricate an HTTP status, latency, or health classification. Report unavailable values and concrete failure reasons explicitly.
- Preserve configured instance order in collector output.
- Treat a failed instance check as collected data rather than a collector process failure.
- Keep `live_instances` optional and retain existing fleet behavior when it is absent or empty, except for the documented empty Live Operations facts section and the unconditional prompt guidance that knows when to omit recommendations.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, or `.git/**`.
- Run the configured repository verification command after the phase.

## Phase 1 - Collect and Surface Live Instance Health

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=examples/sample-fleet-config.json -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Add executable `lib/ops/collect-fleet-health.sh` with this interface:

   ```text
   collect-fleet-health.sh <fleet-config.json>
   ```

   It must read the supplied JSON file and write only a Markdown fragment to standard output.

2. Accept an optional top-level `live_instances` field containing an array of objects with exactly two fields:

   ```json
   {
     "name": "Netdoctor",
     "url": "https://netdoctor.example.com/health"
   }
   ```

   Each `name` and `url` must be a non-empty string, and entries containing missing or additional fields are invalid. The URL must begin with `http://` or `https://`, matched case-insensitively. Its authority component—the characters after the scheme delimiter and before the first `/`, `?`, or `#`—must be non-empty and must not contain `@`, thereby rejecting URL userinfo such as `user@host` or `user:password@host`. Missing or empty `live_instances` must print exactly:

   ```md
   ### Live Instance Status

   No live instances configured.
   ```

3. Exit nonzero with a clear stderr message when the input file is missing or unreadable, contains invalid JSON, has a non-array `live_instances` value, or contains an invalid entry under requirement 2. Do not issue any HTTP request when configuration validation fails.

4. Structure the collector with distinct top-level validation, collection, and rendering functions for live instances. Avoid a monolithic loop tied to all possible signal types, so a later ticket can add an independent `social_accounts` dispatch without restructuring live-instance validation or collection.

5. For every valid configured instance, invoke `curl` exactly once using a GET request, discarding the response body and including:

   - redirect following bounded by `--max-redirs 1`;
   - `--max-time 10`;
   - explicit initial-URL and redirect protocol restrictions allowing only HTTP and HTTPS;
   - no retry option;
   - output capture sufficient to obtain the final HTTP status and curl-reported total request time;
   - no authentication headers, cookies, request body, credential options, or state-changing method;
   - `--` immediately before the URL so a configured URL cannot be interpreted as a curl option.

6. Treat a curl `time_total` value as syntactically valid only when it matches `^[0-9]+([.][0-9]+)?$`. Use the valid value as the elapsed request time and convert it deterministically to integer milliseconds by padding or truncating the fractional portion to exactly three digits, never rounding. Perform the conversion in Bash without adding another executable dependency solely for timing. Use the unrounded value when deciding whether the 2000 ms threshold was reached, so a duration at or above exactly 2.000000 seconds is degraded and a lower duration is healthy.

7. Map zero-exit curl results as follows:

   - `down` with reason `invalid-curl-output` and latency `unavailable` if `time_total` is missing or syntactically invalid, regardless of any emitted HTTP status;
   - `healthy`: final HTTP status is 2xx and valid total time is below 2.000000 seconds;
   - `degraded`: final HTTP status is 2xx and valid total time is at least 2.000000 seconds, or the final status is 3xx;
   - `down`: final HTTP status is 4xx or 5xx;
   - `down`: any other status, with `unexpected-http-status` rendered instead of treating that status as a recognized HTTP result.

   A recognized final HTTP status for this feature is a three-digit integer from 100 through 599. A missing, malformed, or out-of-range status on an otherwise parseable zero-exit result must follow the `unexpected-http-status` rule.

8. Map nonzero curl exit codes to these stable reasons:

   - exit code 28: `timeout`;
   - exit code 7: `connection-refused`;
   - exit code 6: `dns-error`;
   - every other nonzero exit code: `unknown-error`.

   A failed request must be classified `down`, and its mapped failure reason must be rendered in place of an HTTP status even if curl emitted a status before failing. The collector must continue checking later instances and exit zero after reporting all configured check outcomes.

9. For configured instances, print this deterministic Markdown structure in configuration order:

   ```md
   ### Live Instance Status

   - **<name>** (<url>): <classification> — HTTP <status-or-reason>, <latency>ms
   ```

   Normalize embedded carriage returns and newlines in rendered names and URLs to single spaces so they cannot inject additional Markdown lines. Preserve the original validated URL string when passing it to curl. For a nonzero curl invocation, report the curl-provided elapsed time when it is syntactically valid under requirement 6; otherwise render `unavailable` in place of the latency, producing `unavailablems` under the fixed structure above. For a zero-exit invocation with invalid timing output, render `invalid-curl-output` and `unavailablems` as specified in requirement 7.

10. Extend `validate_fleet_discover_config` in `bin/e3d-pilot` to accept an absent `live_instances` field and enforce the same array, exact-entry-shape, non-empty string, HTTP(S) scheme, non-empty authority, and no-userinfo requirements when it is present. Match the command’s existing error-reporting style for optional fleet configuration fields.

11. In `fleet_discover_stage`, after the existing repository facts have been written and before the provider prompt is built:

   - append one blank-line-separated `## Live Operations` heading to the facts file;
   - invoke the collector with the resolved fleet configuration path;
   - append its Markdown output to the same facts file;
   - treat malformed configuration or an unexpected collector process failure as a stage failure;
   - allow reported `degraded` and `down` instances without failing the stage.

12. Resolve the collector relative to the installed e3d-pilot source tree, consistent with existing helper-script invocation in `bin/e3d-pilot`, so the command works when launched from another working directory.

13. Extend `build_fleet_discover_prompt` with an unconditional instruction governing a possible `### Operational Recommendations` section:

   - create one recommendation for every `degraded` or `down` entry in the Live Operations facts;
   - name the specific instance and observed classification;
   - preserve the reported status or failure reason;
   - give one concrete diagnostic or recovery next step grounded in that observation;
   - omit the entire section when all configured instances are healthy or no instances are configured;
   - never invent an instance, status, latency, cause, or recommendation entry.

14. Add `examples/sample-fleet-config-with-ops.json` alongside the existing example. Preserve the existing provider configuration shape and add several clearly fictional `.example.com` live instances. Do not place real production endpoints or credentials in the example.

15. Update the existing README fleet-discovery documentation to describe:

   - the optional `live_instances` array and its `name`/`url` fields;
   - the HTTP(S)-only, bounded, unauthenticated, read-only nature and daily cadence of checks;
   - the Live Operations facts section;
   - when `### Operational Recommendations` is emitted or omitted;
   - the new operations example configuration;
   - social engagement signals as a planned follow-on that is not implemented here.

16. Add `tests/phase24.sh` using the established fake-executable-on-`PATH` convention. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network.

17. Keep changes focused on this feature. Do not alter existing scoring, ranking, ledger materialization, focus selection, single-repository stages, or provider dispatch behavior.

### Acceptance Criteria

- `tests/phase24.sh` supplies a fake `curl` earlier on `PATH`, records every invocation, and fails if the collector bypasses that stub.
- Fixture responses cover a fast 2xx result, a 2xx result at or above 2.000000 seconds, a final 3xx result, a 500 result, a timeout, connection refusal, DNS failure, an unknown curl failure, a nonzero failure with unavailable or malformed curl timing, and a zero-exit result with unavailable or malformed curl timing.
- Collector output for those fixtures exactly matches the required heading, ordering, classifications, statuses or reasons, deterministic integer latency conversion, and unavailable-latency fallback.
- The fake-curl trace proves one invocation per configured instance, no retries, `--max-time 10`, `--max-redirs 1`, HTTP(S)-only protocol restrictions, and an option terminator immediately before each URL.
- A missing or empty `live_instances` field prints the exact “No live instances configured.” fragment and exits zero without invoking curl.
- Invalid JSON, a non-array `live_instances`, an entry with missing or additional fields, an empty or non-string required field, a non-HTTP(S) URL, a URL with an empty authority, and a URL containing userinfo each fail clearly before any curl invocation.
- A failed check renders the mapped failure reason even if the fake curl also emits an HTTP status, does not stop later configured instances from being checked, and does not make the collector exit nonzero.
- A zero-exit check with missing or malformed timing is rendered as `down` with `invalid-curl-output` and `unavailablems`, without fabricating a threshold-based classification.
- A fixture containing escaped carriage-return or newline characters in a name or URL cannot inject additional Markdown list items or headings, while the fake-curl trace proves the original validated URL value was passed as one argument.
- Fleet config validation accepts valid absent, empty, and populated `live_instances` configurations and rejects every malformed shape covered above.
- A stubbed `fleet discover` run with no live instances adds the empty `## Live Operations` facts section while preserving the pre-existing portfolio facts content and ordering.
- A stubbed `fleet discover` run with a down instance includes its rendered observation in the facts file and includes prompt instructions for `### Operational Recommendations`.
- Prompt tests confirm recommendations are required only for degraded or down facts and that the model is explicitly told to omit the entire section for healthy-only or unconfigured facts.
- The README and operations example agree with the implemented configuration and output formats.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes.
- The final diff touches no more than the five declared files, remains below 400 changed lines, and modifies no protected path.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, tightly scoped (5 files, clear line budget), and fully specifies validation, classification, timing conversion, rendering, and test coverage with no contradictions.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, tightly scoped (5 files, clear line budget), and fully specifies validation, classification, timing conversion, rendering, and test coverage with no contradictions.
```

### Reviewer 2: codex

Status: approved

Reason: The draft is internally consistent, implementation-ready, tightly scoped, and provides precise validation, collection, rendering, integration, security, and test requirements.

Raw Response:

```text
---STATUS---
status: approved
reason: The draft is internally consistent, implementation-ready, tightly scoped, and provides precise validation, collection, rendering, integration, security, and test requirements.
```

## Final Outcome

Converged in round 3.
