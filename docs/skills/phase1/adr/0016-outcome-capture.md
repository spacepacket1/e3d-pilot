# ADR-0016: Asking users to record outcomes

Status: **Owner-decided 2026-11-23; recorded here and awaiting reviewer sign-off like the other ADRs.** Phase: calibration 1. Spec: `spec/e3d-pilot-calibration-spec-v0.1.md`.

## Context

Calibration needs outcomes, but the hosted decision-record spec forbids prompting for them so that the outcome rate stays an honest signal. In host mode (the user's own agent) Pilot has no screen to prompt on.

## Decision

1. **Never prompt by default.** No email, notification or in-product nudge asks for an outcome. 2. An **opt-in reminder** setting exists. When on, the user's agent includes one line at the end of a task asking how it went (carried in the tool description and the served skill's metadata only while the setting is on); in Pilot's own screens it is a visible, dismissible prompt. 3. Every use records `reminder_enabled`, and every track record reports `reminded_share` and the resolution rate beside any success rate.

## Consequences

Data arrives slower than with default prompting, and reminded users may differ from others; the shown shares make that visible. If fewer than 15% of reported uses have an outcome 60 days after the host phase ships, capture work stops expanding (ADR-0018).

## Alternatives considered

Never prompt and no opt-in (data may never reach the gates); prompt by default (breaks the decision-record rule and biases who reports).
