# Debate

**Question:** Prior debate verdict (docs/debates/2026-10-06-e3d-ai-appliance): don't sell hardware first; sell governed operations as a managed service (cloud or later appliance), proving ONE HVAC workflow (inbound request -> cited estimate packet + follow-up queue; read-only tools, approval packets for writes, hash-pinned fail-closed policy code for RED actions) on the existing Mac mini with Qwen, then one outside contractor paying >=$1,000/month. Defensible = policy kernel, vertical workflows/integrations, exception+outcome data, measured Qwen-vs-frontier routing table.

New question: how should a product offering like this -- delivered as cloud service or hardware appliance, using mostly local/open models (Qwen) with frontier models (Claude/Codex) as escalation -- be used by small businesses to streamline and automate processes including but not limited to marketing, lead handling, proposals/estimates, accounting, finance, logistics, scheduling, customer follow-up, etc.? Focus on HVAC but generalizable to plumbing, roofing, electrical, carpentry, catering and other trades/service SMBs.

Existing E3D ecosystem pieces (inventory, verify against reality as you reason): e3d-corp (gathers evidence, scores opportunities, drafts proposals, human-approval gate before touching the outside world; authority levels; risk-guard/decision-guard prototype merged), e3d-pilot (discover/ideate/approve/draft/negotiate/execute/review/publish/outcome ledger, e3d-debate multi-model debate, provenance graph, provider adapters), codex-spec-runner (phased spec execution with per-phase model routing; QwenCodingProvider being designed), futco-mcp (knowledge base MCP), e3d-oppscan (paid AI-opportunity-scanner report product, Stripe credits via e3d.ai payments), e3d-applied (FutCo marketing site with booking flow), e3d-cast, e3d-pod2vid (content/video + multi-platform social posting), e3d-mcp / e3d-agent (MCP + agent scaffolds, payments/entitlements), e3d-netdoctor/pcap (network diagnostics), a local Qwen API on a Mac mini, and E3D's own HVAC automation business as live testbed. Trading/on-chain repos (e3d-trade, e3d-maps) are mostly irrelevant to SMB ops.

Ground rules for the integration strategy: (a) for systems SMBs ALREADY use (e.g. ServiceTitan, Jobber, Housecall Pro, QuickBooks/Xero, Google Workspace/Gmail/Calendar, Google Business Profile, Stripe/Square, Twilio/phone, Facebook/Google Ads, Angi/Thumbtack/HomeAdvisor, Mailchimp, supplier/distributor portals) rank integration HIGHER than replacement -- meet them where they are; (b) where E3D must build or adopt something new, prefer open source (e.g. open-source CRM/ERP/accounting/scheduling/telephony/RAG/workflow/ASR/TTS/orchestration tools) over bespoke or proprietary SaaS.

Please give a concrete recommendation covering: 1) the ranked list of SMB processes to automate first and why (value, risk class GREEN/YELLOW/RED, measurability); 2) reference architecture: connectors/integration layer, workflow engine, agent runtime, policy kernel, model router (Qwen vs frontier), memory/knowledge, approval UX, audit/outcomes; 3) a ranked integration list (existing SMB systems first, then open-source building blocks) with which to do first; 4) a gap analysis: which E3D components to reuse as-is, extend, or what must be newly built, and what to NOT build; 5) how it generalizes from HVAC to other trades via a vertical template layer, and what stays constant; 6) cloud vs hardware delivery implications (data residency, latency, support); 7) the first 90-day build sequence tied to the earlier go/no-go gates, and the top risks. Prefer specifics over survey.

**Jev pre-screen (shadow mode, informational only):** obviousness noul=0.11 (1.0 = clearly obvious, 0.0 = clearly needs debate) -- logged for calibration, does not affect whether this debate runs.

## Round 1 -- claude

**Recommendation: sell a "governed back-office operator" for trades. It's a managed cloud service first. It sits on top of the tools the contractor already uses and starts with one wedge, speed-to-lead plus estimate packets. I haven't verified the E3D repo inventory against disk, so the reuse calls below rest on your description.**

**1) Process ranking (value / risk / measurability)**
1. **Inbound lead capture and triage.** Sources are calls, missed-call text-back, forms, Angi/Thumbtack and email. Output is a classified lead, a reply draft and a follow-up queue. GREEN/YELLOW. Measure response time and booked rate.
2. **Cited estimate/proposal packet.** Inputs are the intake, a price book and supplier cost. A human approves before anything is sent. YELLOW. Measure turnaround and close rate.
3. **Follow-up and review requests.** This covers quote nudges, post-job reviews and maintenance-plan renewals. YELLOW with templates. Measure revenue recovered.
4. **Scheduling and dispatch suggestions.** Propose only, no auto-booking at first. YELLOW. Measure drive time and reschedules.
5. **Invoicing and AR chasing.** Draft invoices and reminders. Payment terms and refunds are RED. Measure DSO.
6. **Bookkeeping categorization and weekly cash digest.** Read-only to start, then proposals. YELLOW. Measure hours saved.
7. **Marketing.** GBP posts, review replies and seasonal campaigns. YELLOW. Measure attribution, which is weak here.
8. **Supplier ordering and logistics.** Do this last. Most of it is RED, and the portals are poor.

RED actions are anything touching money movement, contracts, pricing overrides, refunds, licensing or safety claims, and anything binding. They go through hash-pinned fail-closed policy code.

**2) Reference architecture**
- **Connectors:** read-only by default, one adapter per system, with scoped OAuth.
- **Workflow engine:** n8n or Temporal. I'd choose Temporal for durable approval waits, and n8n only if the team wants a visual builder for ops staff.
- **Agent runtime:** typed tool-calling steps. Reuse the codex-spec-runner phase and routing pattern rather than free-roaming agents.
- **Policy kernel:** the risk-guard/decision-guard prototype, extended with authority levels per tenant and action class.
- **Model router:**
  - Qwen for classification, extraction, drafting and summarization.
  - Frontier models for ambiguous estimates, long documents, and anything that fails a confidence or verification check.
  - Route by a measured table, per task and per tenant. Log cost, latency and accuracy.
- **Memory/knowledge:** Postgres plus pgvector, with per-tenant price book, job history, SOPs and a futco-mcp-style KB.
- **Approval UX:** SMS, email and Slack one-tap cards showing the diff and the citations. Put a web inbox behind them.
- **Audit/outcomes:** the e3d-pilot provenance graph and outcome ledger, one record per action with who approved it, which model ran it and what happened.

**3) Integrations, in order**
1. Gmail/Google Calendar/Workspace.
2. Twilio/phone: missed-call text-back, then call transcripts via Whisper-class ASR.
3. Jobber and Housecall Pro. They have open APIs. Pick whichever the pilot contractor uses.
4. QuickBooks Online, read-only first.
5. Google Business Profile.
6. Stripe/Square, read-only.
7. Angi/Thumbtack lead-email parsing. The APIs are weak, so parse the emails.
8. ServiceTitan. It's enterprise-leaning and its API is gated, so wait for pull from customers.
9. Meta/Google Ads, Mailchimp, supplier portals.

Open-source building blocks, adopt only where there's a gap:
- Postgres, Temporal or n8n, whisper.cpp, Piper for TTS, Cal.com for booking, Chatwoot for inbox, Langfuse for traces, Metabase for dashboards.
- Skip ERPNext, Odoo and Twenty for now.

**4) Gap analysis**
- **Reuse as-is:** e3d-pilot ledger and provenance, e3d-debate for routing evaluation, the e3d-corp approval gate, e3d-oppscan Stripe credits, e3d-applied booking, futco-mcp.
- **Extend:** risk-guard into a multi-tenant policy kernel, codex-spec-runner into a runtime for workflow steps, and e3d-mcp/e3d-agent into the entitlement layer.
- **Build new:**
  - Tenant isolation.
  - A connector SDK with replay and fixtures.
  - The HVAC template: price book, estimate schema, follow-up cadences.
  - The approval inbox.
  - An eval harness on real contractor data.
- **Don't build:** a CRM, a scheduler, accounting, field-service software, a general chat UI, or a hardware SKU. Also skip the content/video repos and the trading repos.

**5) Generalization**
The constant core is the connectors, policy kernel, router, approvals and ledger. The vertical template layer holds these items:
- ontology: job types, pricing units
- price book schema
- estimate template and compliance clauses
- seasonal follow-up cadences
- RED list
- KPIs

HVAC has maintenance plans and seasonality. Roofing adds storm surges and insurance-claim paperwork. Catering is event-based, not job-based, so that's the biggest template stretch. Plumbing and electrical are nearly identical to HVAC apart from permit and licensing rules.

**6) Cloud vs hardware**
- **Cloud first.** It gives fast iteration and no field support.
- **Qwen:** keep inference at E3D (Mac mini now, a rented GPU later) with a no-training-on-customer-data promise. Frontier escalation sends only redacted fields.
- **Appliance:** a later upsell for data-residency-sensitive customers, once the unit economics and update channel are proven. The latency win is small, because the humans are the bottleneck.

**7) 90 days**
- **Days 0–30:** E3D HVAC testbed. Gmail, Twilio and the Jobber read path. Lead triage plus estimate packet in shadow mode. Build the eval set and the first routing table.
- **Days 30–60:** Approval inbox, follow-up queue and the policy kernel with the RED list. Go/no-go gate: at least 70% of packets accepted with light edits, and zero policy violations.
- **Days 60–90:** Onboard 1–2 outside contractors on a paid pilot. Add QuickBooks read and AR drafts. Gate: one contractor paying at least $1,000/month.

**Top risks**
1. Integration drift and API gating.
2. Estimate errors with liability attached.
3. Outside contractors won't tolerate the approval friction.
4. Long sales cycles. Mitigate by selling the outcome (speed-to-lead) with a per-booked-job guarantee.
5. Qwen quality gaps, which the routing table should catch.

**Load-bearing assumptions:** contractors will grant read access to their tools, and the speed-to-lead plus estimate wedge is enough to justify $1,000 a month.

## Round 1 -- codex

Recommendation: sell a **governed operations layer**, not a general AI employee. It should observe existing systems, assemble evidence-backed work, route exceptions, and require approval before consequential writes.

1. **Automation order**

1. **Inbound lead → cited estimate packet → follow-up queue** — highest revenue/time value; GREEN extraction/research, YELLOW draft/pricing suggestions, RED sending/commitment. Measure acceptance without substantive edits, handling time, response time, conversion, exceptions.
2. **Lead qualification and scheduling recommendations** — GREEN classification; YELLOW proposed slot/dispatch; RED confirmed appointment or promise. Measure speed-to-lead, booking rate, reschedules.
3. **Post-job follow-up** — draft review requests, maintenance reminders, unpaid-invoice reminders. YELLOW drafts; RED external sends/payment terms. Measure approvals, collections, repeat bookings.
4. **Job-file QA and logistics** — detect missing permits, photos, equipment, parts, purchase-order discrepancies. Mostly GREEN alerts; RED orders/returns. Measure prevented revisits and exception precision.
5. **Marketing content/campaign analysis** — GREEN reporting, YELLOW drafts, RED publishing or budget changes. Measure attributable leads, not content volume.
6. **Accounting/finance** — initially reconciliation suggestions and anomaly queues only. Any journal entry, payroll, refund, payment, credit, tax, or financing action is RED.

Never begin with autonomous dispatch, dynamic pricing, bookkeeping writes, ad spend, purchasing, or customer commitments.

2. **Reference architecture**

`connectors → normalized business events → durable workflow engine → bounded agent tasks → policy kernel → approval/write executor`

Use OAuth/webhooks plus polling adapters; Temporal for durable workflows; containerized workers with MCP/tool contracts; Postgres plus object storage, with pgvector only when semantic retrieval proves necessary. Qwen performs extraction, classification, retrieval, drafting, and routine validation. Escalate on low confidence, missing evidence, policy-triggered complexity, or observed failure—not merely task names. Claude/Codex handle hard synthesis; humans handle RED.

Policy is deterministic, versioned, hash-pinned, outside model reach, and fail-closed. Approval packets show proposed action, exact diff, citations, risk, model, policy version, expiry, and approve/reject/edit. Record inputs, evidence, decisions, costs, latency, edits, exceptions, and business outcomes. The TypeSafe-influenced rule is useful: code owns workflow and permissions; models return narrow typed judgments with calibrated routing signals—not authority. [TypeSafe pattern](https://docs.typesafe.ai/llms.txt)

3. **Integration priority**

1. Gmail/Google Workspace and Calendar  
2. Existing field-service platform: Jobber/Housecall Pro first for attainable SMB pilots; ServiceTitan adapter next  
3. QuickBooks Online, then Xero  
4. Twilio/phone/SMS  
5. Google Business Profile  
6. Stripe/Square  
7. Angi/Thumbtack/HomeAdvisor lead ingestion  
8. Supplier portals through email/CSV before brittle browser automation  
9. Ads/Mailchimp only after the core workflow passes  

Open-source foundations: Temporal, Postgres/pgvector, MinIO, Keycloak, OpenTelemetry, n8n as an edge connector—not the policy authority—plus optional Twenty/ERPNext/FreePBX/Whisper where customers lack systems.

4. **E3D gap analysis**

Reuse e3d-corp’s evidence/proposal/approval/authority/outcome primitives and merged risk prototype; e3d-pilot’s ledger, provenance and adapters; Pilot’s existing local OpenAI-compatible Qwen path; futco-mcp patterns; e3d-applied/oppscan for funnel and payments.

Extend these into tenant-safe business events, connector SDK, typed workflow schemas, approval inbox, outcome metrics, and replayable evaluations. codex-spec-runner routing is for software delivery; its QwenCodingProvider is not yet a production SMB runtime.

Do not build CRM, accounting, scheduler, telephony, vector database, generic agent framework, or hardware.

5. **Vertical templates**

Keep connectors, policy, approvals, audit, routing, identity, and outcomes constant. Templates supply vocabulary, intake schema, estimate sections, price-book rules, evidence requirements, exceptions, KPIs, and action policy. Swap HVAC equipment/load data for plumbing fixtures, roofing measurements, electrical panels, catering headcount/allergens, etc.

6. **Delivery**

Cloud first: faster updates and support, centralized frontier escalation, isolated tenant encryption. Offer an edge worker for credentials, documents, ASR, and Qwen. Appliance later only for residency, poor connectivity, or predictable low latency; signed updates and remote diagnostics are mandatory, while E3D avoids inventory/RMAs.

7. **First 90 days**

- Days 1–30: one internal HVAC connector path, event schema, estimate packet, Qwen/frontier telemetry, policy tests and approval inbox.
- Days 31–45: two-week shadow mode.
- Days 46–60: supervised operation; reach 100 cases.
- Days 61–75: integrate one outside contractor’s actual stack and run paid shadow mode.
- Days 76–90: sign ≥$1,000/month only if acceptance ≥70%, handling time falls ≥50%, zero RED escapes/material errors, and fully loaded cost is <20% of measured value. Appliance positioning additionally requires ≥70% Qwen-only completion.

Top risks: hidden exception labor, connector brittleness, incorrect citations/pricing, approval fatigue, RED escape, weak outcome attribution, and cross-tenant leakage.

## Round 1 -- devin

## SMB Ops Product Architecture — Direct Answer

**Load-bearing assumptions:** Prior verdict stands. One external contractor paying ≥$1K/month is the gate before any expansion. Everything below is staged to that gate.

---

### 1. Ranked processes to automate first

| # | Process | Risk class | Why first |
|---|---------|-----------|-----------|
| 1 | Inbound lead triage + response draft | GREEN/YELLOW | Missed leads = direct revenue loss; volume is measurable |
| 2 | Estimate/proposal packet generation | YELLOW | Highest owner time sink; win-rate is a clean outcome metric |
| 3 | Customer follow-up + review solicitation | GREEN | Low risk, high volume, measurable (conversion, review count) |
| 4 | Scheduling/dispatch suggestions | YELLOW | Labor efficiency; measurable via utilization and drive time |
| 5 | Invoice draft + AR follow-up | YELLOW→RED | Cash flow; drafting is YELLOW, *sending* is RED |
| 6 | Supplier order drafts | YELLOW→RED | Parts ordering: draft YELLOW, execute RED |
| 7 | Job cost/accounting sync | YELLOW | Measurable against QB/Xero; low risk if read-only |
| 8 | Marketing copy + social scheduling | GREEN | Lower cash-flow urgency; good automated volume |

**Not yet:** payroll, tax filing, equipment control, payment execution, dispatch commitments.

---

### 2. Reference architecture

```
[Gmail / Twilio / Jobber / QB / GBP / Stripe]
              ↓
    n8n (self-hosted workflow engine + connectors)
              ↓
    e3d-corp agent runtime (authority levels, risk-guard)
              ↓
    Policy kernel [hash-pinned, fail-closed, deterministic RED enforcement]
              ↓
    Model router: Qwen (local) → Claude/Codex (frontier fallback, logged)
              ↓
    Memory: futco-mcp + Chroma/Qdrant (job history, pricing, product catalog RAG)
              ↓
    Approval UX: email-link approval packets (YELLOW/RED inbox)
              ↓
    Audit ledger: e3d-pilot provenance graph + outcome log
```

---

### 3. Ranked integrations

**Tier 1 — existing SMB systems (integrate, don't replace):**
1. Gmail/Google Calendar (universal OAuth, highest signal)
2. Twilio (inbound SMS/voicemail/call transcription)
3. Jobber or Housecall Pro (job mgmt, scheduling API)
4. QuickBooks Online (invoicing, COA sync)
5. Google Business Profile (review monitoring + response)
6. Stripe/Square (payment status reads)
7. Angi/Thumbtack (lead intake webhooks)
8. ServiceTitan (larger shops; complex but necessary)

**Tier 2 — open-source building blocks (build on, don't buy):**
1. **n8n** (workflow orchestration, self-hosted, MIT, 400+ connectors) — primary glue
2. **Chroma or Qdrant** (vector store for RAG)
3. **Whisper** (local ASR for voicemail/call transcription)
4. **Docling/Marker** (supplier invoice + permit document parsing)
5. ERPNext only if SMB has no existing ERP

---

### 4. Gap analysis

| Component | Action |
|-----------|--------|
| e3d-pilot (provenance graph, provider adapters, debate/approval flow) | Reuse as-is |
| e3d-corp (authority levels, risk-guard/decision-guard) | Reuse; extend with HVAC-specific agent workflows |
| futco-mcp | Reuse as knowledge base |
| Local Qwen API | Reuse; pin to dedicated hours (fix contention first) |
| codex-spec-runner | Extend: per-workflow phase routing (QwenCodingProvider already in design) |
| **Connector layer** (Gmail, Jobber, QB OAuth adapters) | **Build via n8n** — thin wrappers, not bespoke |
| **Approval UX** (email-link approval packets) | **Build** — simplest viable: email with approve/reject links, no app initially |
| **Vertical template config** (YAML per trade: integrations, pricing schema, policy overrides) | **Build** — this is the generalization mechanism |
| Custom workflow engine | **Do NOT build** — use n8n |
| Custom vector DB | **Do NOT build** — use Chroma/Qdrant |
| Custom ASR | **Do NOT build** — use Whisper |
| CRM/accounting/scheduling replacement | **Do NOT build** — integrate |

---

### 5. Generalization to other trades

**Stays constant (the kernel):**
- Policy enforcement (GREEN/YELLOW/RED), hash-pinned, fail-closed
- Model router (Qwen → Claude/Codex with logged fallback)
- Approval UX pattern (email-link packets)
- Core workflow types: lead intake, estimate, follow-up, invoice
- Audit/outcome ledger

**Vertical template layer (varies):**
- Connector config (ServiceTitan → HVAC; BuilderTrend → roofing/carpentry; Toast/Restaurant365 → catering)
- Pricing/estimation logic (material rates, labor, permit costs by trade)
- Regulatory context (licensing, code compliance terminology)
- Supplier/distributor portal integrations
- Document formats (service agreements, lien waivers, health permits)

**Generalization path:** Prove HVAC template → extract vertical config schema → clone for plumbing/roofing/electrical → differentiate only connector + pricing layer. Structural agent logic is ~80% reused.

---

### 6. Cloud vs hardware delivery

| Dimension | Cloud (start here) | Hardware appliance (earn later) |
|-----------|--------------------|---------------------------------|
| Onboarding | Fast, no hardware | Procurement friction |
| Data residency | Concern for PII/financial | Satisfied by default |
| Latency | Acceptable for async workflows | Required only for real-time dispatch/call handling |
| Support cost | Centralized, scalable | Per-device, expensive |
| When to offer | Day 1 | After: data residency objection kills cloud deal AND Qwen passes 70% local gate AND one customer requests it |

**Decision rule:** Sell cloud-managed service first. Hardware appliance is unlocked only by a paying customer who explicitly objects to cloud data residency AND Qwen meets the local completion gate.

---

### 7. First 90-day sequence

**Days 1–14 (pre-production setup):**
- Fix Mac mini contention: priority scheduler, pin Qwen to dedicated hours
- Connect read-only: Gmail + Twilio inbound, Jobber/HCP read API
- Deploy shadow mode: inbound request → estimate packet draft + follow-up queue
- Hash-pin policy file; enforce RED in deterministic code outside the model

**Days 15–42 (supervised production):**
- 100+ real inbound cases through the one workflow
- Approval inbox live (email-link packets for YELLOW)
- Log: handle time, Qwen vs frontier rate, edit rate, RED queue items
- Measure against service gate (70% accepted, 50% time reduction, 0 RED violations, cost ≤20% of value)

**Days 43–60 (gate evaluation + external recruit):**
- Service gate pass? → Recruit one outside HVAC contractor, 2-week shadow mode
- Service gate fail? → Diagnose one root cause, one iteration, re-evaluate. If still failing: stop.
- Appliance gate (Qwen ≥70% local completion): measure separately; gate for hardware packaging only

**Days 61–90 (external paid proof):**
- Supervised production with external contractor
- External commits ≥$1K/month → launch paid cloud service
- Appliance gate passes → scope minimal cloud packaging + certified hardware list
- Begin vertical template extraction for second trade (plumbing/electrical) only if external contractor is stable

**Top risks, ranked:**
1. **Qwen reasoning ceiling** on multi-step estimate generation → frontier costs exceed $200/month delivery cap → economics fail without local Qwen carrying 70%
2. **Integration sprawl** — every SMB uses a slightly different stack; connector maintenance becomes a services business
3. **Exception labor** — agent errors take longer to fix than doing manually; destroys the 50% time-reduction gate
4. **RED escape** — one autonomous email/payment/message destroys trust irreversibly
5. **Data residency objection** blocks cloud onboarding before hardware is ready

---

**Bottom line:** Build the vertical template layer and n8n connector layer as the new work. Reuse e3d-corp/e3d-pilot as the agent + governance backbone. Lead with Gmail+Twilio+Jobber integrations — they cover 80% of HVAC SMB signal. The product is defensible because of the policy kernel + outcome data, not the integrations themselves. Don't generalize to a second trade until the first external contractor is stable and paying.

## Round 1 -- grok-build

I'll verify the prior debate verdict and the actual E3D pieces against the repo, then give a ranked, specific product recommendation.I have the prior verdict. Next I’ll check which E3D repos actually exist and what they already do.**Sell one product: a governed Estimate Desk as a managed service.** Cloud first, Qwen on the existing Mac mini, Claude/Codex only as measured escalation. One HVAC workflow until the prior gates pass: inbound request → cited estimate packet + follow-up queue. Read-only tools; writes as approval packets; RED in hash-pinned fail-closed code. Do not sell a suite, a box, or a replacement for Jobber/Housecall Pro/QuickBooks.

**Assumption that will break this if false:** E3D’s HVAC “testbed” is currently ads + consulting (Meta HVAC scanner campaigns, Applied booking, Calendar poller), not a 100-ticket job book. If internal volume cannot produce 100 real cases in six weeks, shadow-read a peer contractor’s inbox in week 1. Do not simulate tickets.

### 1) Automate in this order
| Rank | Process | Class | Why first |
|---|---|---|---|
| 1 | Ingest email/web/voicemail into a job file | GREEN | Volume, reversible, countable |
| 2 | Cited estimate/job-prep packet (price book + past jobs + photos) | YELLOW draft | Highest $ per owner-hour; edit rate is the metric |
| 3 | Follow-up queue (unanswered quotes, no-shows) | YELLOW draft / RED send | Converts the packet into cash |
| 4 | Review/GBP reply drafts | YELLOW / RED public | Cheap, measurable |
| 5 | Schedule *suggestions* into their calendar/FSM | YELLOW | After 1–3 work |
| 6 | Invoice-nudge drafts | YELLOW / RED money | After estimates close |
| Never in v1 | Dispatch, payments, books, ads spend, legal, equipment control | RED | Exception labor and liability kill the $1,000 P&L |

Map onto existing `e3d-corp` authority: GREEN = L0–1, YELLOW = L2 (approve fires), RED = L3–4 (approve, then confirm).

### 2) Architecture
`Connectors (n8n) → Event store → Workflow (e3d-corp loop) → Agent (schema-only JSON) → Policy kernel → Model router → Approval inbox → Executors → Outcome ledger`

- **Connectors:** Gmail, Calendar, Twilio recordings, one FSM, GBP. n8n; no Temporal in 90 days.
- **Engine/runtime/policy:** `e3d-corp` Event→Opportunity→Proposal→Decision→Action→Outcome→Experience. `ACTION_POLICY` is already versioned and fail-closed; pin its hash. Extend types: `draft-estimate-packet`, `queue-followup`, `send-followup`. Reuse `risk.assess` (HOLD/APPROVE/CHECK) as the YELLOW/RED classifier.
- **Router:** Qwen local default; escalate on schema fail, low citation coverage, or price-book miss. Log model, tokens, latency, accept/edit. That log *is* the routing table.
- **Memory:** LanceDB over price book, past packets, equipment notes. Vertical playbooks as markdown (futco-mcp pattern), customer-scoped.
- **UX:** existing corp proposal web UI + SMS “approve/edit/reject”. Phone is the SMB UI.
- **Audit:** keep the hash-chained log; never treat Decision as Outcome.

### 3) Integrate first
**Already in the shop:** (1) Gmail/Workspace, (2) Google Calendar (corp already lists events), (3) Twilio + faster-whisper, (4) **Housecall Pro or Jobber — pick whichever the first paying contractor runs**, (5) GBP messages, (6) QuickBooks **read-only**.  
**OSS after that:** n8n, faster-whisper, LanceDB, existing corp/pilot local adapters.  
Skip Twenty/Odoo/ERPNext/Asterisk unless they have *no* FSM. Do not replace Stripe/Square/Mailchimp/Angi; read Angi/Thumbtack inbound as just another Gmail source.

### 4) E3D gap
| Reuse | Extend | Build | Do not build |
|---|---|---|---|
| corp policy, proposals, outcomes, local LLM client, Calendar poller, Applied/Oppscan as *lead magnet* | action types, GREEN/YELLOW/RED overlay, SMS approve, Qwen/frontier router with a scoreboard | HVAC packet schema + price-book RAG, Gmail/Twilio/HCP-or-Jobber connectors, mobile-thick approval | CRM, accounting, scheduler, telephony, ads manager, ServiceTitan clone, hardware, CSR `QwenCodingProvider`, trading/mcp/agent/maps/netdoctor in this product |

`QwenCodingProvider` is not in `codex-spec-runner`. `futco-mcp` is an internal repo KB, not customer memory. `e3d-cast`/`pod2vid` wait until the desk is paid.

### 5) Vertical template
**Constant:** policy kernel, connectors, router, approval, ledger.  
**Swap pack:** intake fields, price book, labor/equipment units, compliance phrases, FSM mapping. Plumbing/roofing/electrical/carpentry/catering are the same desk with a different pack. First paid invoice is still HVAC.

### 6) Cloud vs box
Cloud-assisted managed service now (Qwen on the mini, frontier over API). Tenant-encrypted job files; residency is a contract checkbox, not an appliance. Latency is email-scale. Support is the real cost: one certified connector set, no snowflake FSMs. Ship a box only if Qwen finishes ≥70% of cases with no frontier call.

### 7) 90 days, same gates
- **D1–14:** pin Qwen behind one scheduler; Gmail+voicemail ingest; shadow packets; read-only FSM.
- **D15–42:** supervised production, ≥100 real cases.
- **D43–60:** **service go** only if ≥70% accepted without rework, ≥50% less handling time, 0 unapproved RED, fully loaded cost ≤20% of value. **Appliance** only if Qwen ≥70% with no frontier.
- **D61–90:** one outside HVAC contractor at ≥$1,000/month on *this* workflow. If the service gate misses after one iteration, stop.

**Risks, in order:** no real ticket volume; exception labor eating the $1,000; one RED send; HCP/Jobber support sprawl; Qwen too weak (sell cloud-assisted service anyway; do not call it an appliance).

## Round 2 -- claude

**Position holds, with two concessions.**

**Where the field agrees (and I agree):** Managed cloud service first. One wedge: inbound lead → cited estimate packet → follow-up queue. Integrate Gmail, Calendar, Twilio, Jobber/HCP, QuickBooks read-only. Policy kernel with RED in hash-pinned code. No CRM, scheduler, accounting or hardware builds. The hardware appliance waits behind a ≥70% Qwen-only gate. The 90-day sequence is nearly identical everywhere.

**Concession 1: grok-build's repo checks are better than my unverified inventory.**
- I said to reuse the QwenCodingProvider-style runtime. Grok-build says `QwenCodingProvider` isn't in `codex-spec-runner`, and codex says it isn't a production SMB runtime. I haven't checked the disk, so I'm treating both as likely and withdrawing that reuse claim. Extend `e3d-corp`'s Event→Proposal→Decision→Action→Outcome loop instead, and treat codex-spec-runner as a pattern only.
- Grok-build also notes that the HVAC testbed may lack ticket volume. I missed that. It is the sharpest risk in this round, because the 70%-accepted gate is meaningless without about 100 real cases. My days 0–30 should add this fallback: if internal volume is thin by week 2, shadow-read a peer contractor's inbox.

**Concession 2: I'm adopting codex's gate wording.** Acceptance ≥70%, handling time down ≥50%, zero RED escapes, and fully loaded cost <20% of measured value. Mine had only acceptance and zero violations. Without a cost gate, exception labor can eat the $1,000.

**Where I disagree with the others:**

- **Devin's n8n as the primary glue under the agent runtime.** Devin and grok-build both put n8n at the center. n8n is fine for connectors. But approval waits can last hours or days, and the gates need replayable runs. I'd keep n8n at the edge for connectors only, and keep durable state in Postgres plus a workflow engine. Temporal is my pick, but it's a preference. Grok-build's "no Temporal in 90 days" is defensible if the e3d-corp loop already persists state. Whether it does is unverified, and that's the real dispute.
- **Devin's Chroma/Qdrant and grok-build's LanceDB.** A price book plus job history is small. pgvector in the Postgres we already need is enough, and codex's "only when semantic retrieval proves necessary" is better still. Don't add a second datastore.
- **Devin's email-link approvals.** Approve links in email are fine for YELLOW. For RED they're weak, because a forwarded link works for whoever holds it. Use authenticated SMS or web with an expiry and the exact diff, as grok-build and codex say.
- **Devin's "fix Mac mini contention" as a day-1 step.** It's a real issue, but the mini is a dev box. If paying customers depend on it, move Qwen to a rented GPU or a second box before the paid pilot. A single mini is a single point of failure.
- **Grok-build's "Never in v1" list includes review/GBP replies at rank 4, while I and devin rank follow-up and reviews at 3.** This is a minor ordering difference and doesn't change what gets built.
- **Codex's keycloak/MinIO/OpenTelemetry stack.** Too much infrastructure for 90 days and a single-digit tenant count. Use managed auth and Postgres, and revisit at tenant five.

**What changes in practice:** I'd start where grok-build starts, with verifying the repo and the ticket volume. Then I'd use codex's gates and my own durable-state preference. The differences between us are the workflow engine and the vector store, plus how strong the approval channel needs to be for RED. They don't change the 90-day plan or who the first customer is.

POSITION: Sell a governed cloud-managed estimate-and-follow-up desk for one HVAC workflow, integrated with the contractor's Gmail, Twilio, Jobber/HCP and QuickBooks, with deterministic policy and codex's gates, and with the first outside ≥$1,000/month contractor as the proof.
status: approved

## Round 2 -- codex

My position holds, with one architectural correction: do not add Temporal or make n8n the core during the pilot. The verified e3d-corp runtime already supplies the event lifecycle, structured model roles, approval-gated execution, fail-closed action policy, hash-chained log, and distinct outcomes. Add thin connectors around it; use n8n only at the edge if expedient. Devin’s claim that n8n is MIT is incorrect—it is fair-code under the Sustainable Use License. [n8n license](https://github.com/n8n-io/n8n/blob/master/LICENSE.md)

Repo reality also narrows the reuse claims:

- e3d-corp’s policy is versioned and fail-closed, but the policy artifact is not yet hash-pinned; build that verification.
- e3d-pilot’s provenance graph exists but is explicitly experimental, not a production tenant audit service.
- Pilot’s local OpenAI-compatible Qwen adapter exists.
- `QwenCodingProvider` is not implemented and codex-spec-runner should not become the SMB runtime.
- futco-mcp is an internal repository KB pattern, not ready-made customer memory.

The product remains one governed HVAC Estimate Desk: inbound request → evidence-backed estimate/job-prep packet → follow-up queue. Ingestion and classification are GREEN; estimates and schedule suggestions are YELLOW; sending commitments, booking appointments, changing prices, ordering, accounting writes, payments, contracts, and public publishing are RED. Next processes are post-job follow-up, job-file QA, scheduling suggestions, AR drafts, then marketing. Accounting writes, dispatch autonomy, purchasing, and ad-budget control stay out.

Qwen should handle narrow typed extraction, classification, evidence selection, and drafting. Code owns calculation, workflow, permissions, and execution; frontier models receive cases failing schemas, evidence coverage, deterministic checks, or empirically calibrated thresholds. This matches the TypeSafe principle that typed model judgments inform code but do not confer authority. [TypeSafe documentation](https://docs.typesafe.ai/llms.txt)

Claude is directionally correct but proposes too much infrastructure and too many workflows. Devin incorrectly centers n8n, overstates Qwen-local percentage as a product gate, and treats social posting as GREEN when publishing is consequential. Grok is strongest on verified reuse and real-volume risk, but LanceDB and “phone is the UI” are premature choices; one mobile web approval inbox is sufficient.

Days 1–30: Gmail/voicemail plus the pilot’s actual FSM read path, packet schema, policy hashing, approval inbox, telemetry. Days 31–60: 100 real shadow/supervised cases. Days 61–90: one outside contractor’s existing stack and a paid pilot. Proceed only with ≥70% light-edit acceptance, ≥50% handling-time reduction, zero RED escapes/material errors, delivery cost below 20% of measured value, and ≥$1,000/month commitment. Qwen share determines deployment economics—not service viability. Hardware requires explicit paid residency/offline demand plus demonstrated local economics.

POSITION: Prove and sell one governed HVAC Estimate Desk as a cloud-assisted managed service atop existing systems, using e3d-corp as the core and treating hardware as a later customer-driven deployment option.
status: revise

## Round 2 -- devin

**My prior position holds on strategy. Two tactical revisions. Key rebuttals below.**

---

**Where I agree with grok-build and revise my own answer:**

1. **Internal ticket volume is a load-bearing assumption I understated.** If E3D's HVAC "testbed" is currently Meta ad campaigns and consulting engagements—not a live job book with 100+ inbound cases—the shadow-mode gate cannot be validated internally. Corrective action: make sourcing real cases (from a peer contractor's inbox or a booked E3D job queue) a Day 1 deliverable, not a Day 43 fallback.

2. **pgvector over Chroma/Qdrant.** I said Chroma/Qdrant; grok-build and claude both say pgvector in Postgres. Correct. One less service, same capability for this data volume. Revise to pgvector.

3. **QwenCodingProvider is not yet in codex-spec-runner.** Grok-build is right to call this out. I said "extend codex-spec-runner for per-workflow phase routing"—that's aspirational, not current. In the 90-day scope, don't depend on it. Reuse the routing pattern conceptually; build the actual router as a thin function in e3d-corp.

---

**Where I hold against claude and codex:**

**Temporal vs n8n.** Claude and codex both recommend Temporal for durable approval waits. I disagree for the 90-day scope. Temporal requires standing up a cluster with a persistence backend and worker infrastructure. n8n is self-hosted in one container and has 400+ connectors already built. Email-link approval packets don't require Temporal's durability guarantees in v1—an unanswered YELLOW draft can simply timeout and re-queue. Adopt Temporal if approval wait states prove brittle after the first external contractor. Not before.

**codex: "pgvector only when semantic retrieval proves necessary."** Wrong sequencing. The estimate packet requires price-book retrieval against a catalog of parts and labor rates. That's semantic retrieval. It's required from week 1, not optional. Build pgvector into the initial schema.

---

**Where all four answers converge (confirm, don't debate):**

- Cloud first, no hardware until Qwen ≥70% local gate passes
- Gmail + Twilio + Jobber/HCP as first integrations
- Inbound lead → estimate packet → follow-up queue as the single wedge workflow
- Policy kernel: hash-pinned, fail-closed, deterministic, outside model reach
- RED actions never autonomous in v1
- Gate: 70% acceptance, 50% handling time reduction, zero RED escapes, cost ≤20% of value, one external contractor at ≥$1K/month

---

**One thing no answer including mine stated sharply enough:** The approval UX must work on SMS. Trades contractors are on-site, not at desks. An email-link approval packet that requires opening a laptop will fail. Day 1 design: SMS one-tap approve/reject with the diff in the body. Web inbox is the fallback, not the primary.

---

**Revised top risks (reordered):**

1. Insufficient real internal ticket volume → shadow mode gate is fiction
2. RED escape destroys trust irreversibly
3. Exception labor from agent errors exceeds manual baseline → 50% time-reduction gate fails
4. Approval UX friction (email-only) → contractor churns before the gate
5. Qwen ceiling on multi-step estimates → frontier cost exceeds unit economics

---

POSITION: Sell a governed Estimate Desk as a cloud managed service; first 90 days are one HVAC workflow (inbound → cited estimate packet → follow-up queue) using n8n + e3d-corp + pgvector, with real cases sourced Day 1 and a single external contractor paying ≥$1K/month as the only exit gate.
status: approved

## Round 2 -- grok-build

I'll check the few claims the other answers still disagree on—where inference runs, what the policy kernel already is, and whether the HVAC testbed can supply real tickets.My position holds: sell one governed Estimate Desk as a managed service. Two corrections after checking the other answers against the code.

**Corrections.** I over-classed private follow-up sends as RED. In `e3d-corp` `lib/authority/policy.js` (policy v4), unknown action types already fail closed. L0–1 are autonomous (ingest, draft). L2 is one approval that executes the send. L3–4 (invoice, payment, public, irreversible) need `confirmAndExecute`. Private quote nudges are L2. Google Business Profile replies and anything that states price, terms, or a commitment are L3–4. Drop LanceDB. A structured price book in Postgres is enough until lookup misses. Codex is right that a vector index is optional. Devin's Chroma/Qdrant on day 1 is extra surface.

**Where the others would build the wrong thing.** Devin marks follow-up GREEN and would auto-send, skipping the approval packet. Devin also points customer memory at futco-mcp and extends `QwenCodingProvider`. futco-mcp is a private internal markdown knowledge base for coding sessions, with no database. `QwenCodingProvider` is not in `codex-spec-runner`. n8n must not be the policy authority. `assertProposalAuthorized` already is.

Claude's engine is Temporal, and the day-30 gate drops the 50% handling-time cut and the fully loaded cost ≤20% of value. That starts a paid pilot on acceptance rate alone and spends month one on a second runtime. Pre-approved templates must not become a standing send grant.

Codex is closest, with two splits. Do not stand up Temporal in 90 days: corp's event log already waits on Decisions. Do not ship a customer edge worker. Qwen stays on E3D's mini. OAuth credentials stay in the managed service. An edge box is the appliance, gated on ≥70% Qwen-only completion after the service is paid. Double-confirm on every nudge will burn the owner and fail the time gate. Reserve it for L3–4.

**Do this.** One workflow: inbound email/voicemail → cited estimate packet → follow-up queue. n8n only as connectors: Gmail, Calendar, Twilio recordings, and whichever of Housecall Pro or Jobber the first payer uses. QuickBooks stays read-only until after the gate. Angi/Thumbtack arrive as Gmail. No ServiceTitan, ads, or supplier portals.

Router: Qwen by default. Escalate on schema failure, missing price-book lines, or thin citations. The accept/edit log is the routing table. Approval UX: the corp proposal screen plus SMS approve/edit/reject.

Days 1–14: if E3D HVAC cannot yield 100 real cases, shadow-read one peer inbox immediately. Do not simulate tickets. Days 15–42: supervised, ≥100 cases. Days 43–60: go only if ≥70% are accepted without rework, handling time drops ≥50%, unapproved L2+ sends are zero, and cost ≤20% of value. Days 61–90: one outside HVAC contractor at ≥$1,000/month on this workflow only. One miss after one iteration: stop.

The vertical pack (intake fields, price book, compliance lines) waits on that invoice. Plumbing through catering swap the pack, not the kernel.

**Risks:** no real ticket volume; exception labor; one unapproved send; field-service connector sprawl; a weak Qwen, which still leaves a cloud-assisted service.

POSITION: Sell a cloud-managed HVAC Estimate Desk on e3d-corp's existing authority table—one approve-to-send for private follow-ups, double-confirm for money and public writes—and do not add Temporal, a vector database, an edge box, or a second workflow until one contractor pays ≥$1,000/month.
status: revise

## Round 3 -- claude

**My position holds, with two adoptions and one remaining split.**

**Adopting from others:**
- **Grok-build's authority table.** Private quote nudges are L2: one approve-to-send. L3–4 (money, public, irreversible) get `confirmAndExecute`. That's better than my blanket RED framing for follow-ups, and double-confirming every nudge would burn the owner and fail the time gate. I haven't re-read `policy.js` myself, so I'm relying on grok-build's check.
- **Codex's correction on hash-pinning.** The policy artifact is versioned and fail-closed but not hash-pinned. That is a build item, not a reuse item. The earlier verdict's "hash-pinned code" claim shouldn't be treated as existing.

**Remaining split: workflow engine (Temporal vs none vs n8n).** I've moved toward the field. If e3d-corp's event log already persists Decisions and waits on them, a second runtime adds cost for no gain in 90 days. I now say: **no Temporal until the e3d-corp loop is shown to lose approval-wait state across restarts.** That is a day-1 test, not a debate. If it fails, add Temporal. If it passes, skip it. Everyone but devin can accept this. Devin's n8n-as-core is the outlier. n8n sits at the edge for connectors only, and as codex notes its license is fair-code, not MIT. Fine for self-run connectors, but a legal question if E3D redistributes it to customers.

**Where I still hold against the others:**

- **Devin's pgvector-from-week-1.** A price book is structured data: SKU, labor hours, rate, region multiplier. Exact and fuzzy lookup in Postgres handles it. Embeddings are for the messy part, matching free-text "my AC is making a clicking noise" to likely causes and past jobs. Use them only if lookup misses show up in shadow mode. Grok-build and codex are right to defer.
- **Devin's "SMS is the primary UI."** SMS approve is right for YELLOW nudges. An estimate packet with citations and line items needs a screen. Use SMS as a notification and one-tap approve for simple items, and a mobile web page for the packet. Codex's "one mobile web approval inbox" and devin's SMS are compatible when the SMS carries a link to the inbox, authenticated, with an expiry.
- **Grok-build's "Qwen stays on E3D's mini."** I'd keep this only for the shadow phase. The first paying contractor shouldn't depend on one dev machine. Fix inference before the paid pilot, using a rented GPU, a second box, or frontier-only for that tenant. Economics then become a measured number rather than an assumption.

**Everything else is shared:** one wedge workflow, Gmail/Calendar/Twilio plus the contractor's Jobber or HCP, QuickBooks read-only, deterministic policy outside the model, codex's four gates, real cases from day 1 (peer inbox if internal volume is thin), and hardware only after the ≥70% Qwen-only gate and paid demand. Vertical pack swaps the intake fields, price book and compliance lines. The kernel, router, approval and audit stay constant.

By the "same action" test, the five answers now differ only in infrastructure details. The first 90 days run the same way for everyone: verify the repo and ticket volume, run shadow mode with gates, then sign one contractor. The differences are the n8n edge, the inference host for the paid pilot, and whether to add a vector index. All three are decided by a measurement.

POSITION: Sell a cloud-managed HVAC Estimate Desk on e3d-corp's existing event loop and authority table, with no Temporal unless a day-1 restart test fails and no vector index until lookup misses appear, and with inference moved off the dev mini before the first paid contractor.
status: approved

## Round 3 -- codex

My position holds, with one refinement: use e3d-corp’s existing authority semantics rather than flattening every external write into RED.

Repo reality supports Grok’s correction: e3d-corp already has a replayable, hash-chained Event→Proposal→Decision→Action→Outcome lifecycle. L2 private sends execute after one logged approval; L3–4 financial, contractual, public, or irreversible actions require approval plus separate confirmation. Unknown actions fail closed. However, the event log’s hash chain is not the same as hash-pinning the deployed policy artifact; policy-build verification still must be added.

Codex and Grok are right about the pilot architecture:

- Extend e3d-corp with thin Gmail/voicemail, Calendar, Jobber-or-Housecall-Pro, and read-only QuickBooks connectors.
- Do not introduce Temporal, make n8n authoritative, or turn codex-spec-runner into the SMB runtime.
- Keep structured price books in Postgres. Add pgvector only after measured lookup failures demonstrate semantic retrieval is needed.
- Qwen handles typed extraction, classification, evidence matching, and drafting. Frontier escalation follows schema failure, inadequate citations, ambiguity, or calibrated low confidence—not a fixed quota.
- Ship an authenticated mobile web approval inbox with SMS notifications. SMS alone must not contain bearer-like one-tap authority for sensitive actions.

Devin is right that real ticket supply is the first operational risk, but wrong to center n8n, require pgvector immediately, or treat “Qwen ≥70%” as the cloud-service or hardware gate. Qwen share is an economic measurement. An appliance additionally requires customers willing to pay for residency/offline operation and evidence that E3D can support deployed hardware profitably.

Claude is right that the Mac mini must not become an unacknowledged production dependency. But adding Temporal before e3d-corp’s existing persistence demonstrably fails would create a second orchestration system without validating customer value.

The executable plan remains: source real cases by day 14; build the packet schema, citations, policy-artifact verification, mobile approvals, and telemetry; evaluate at least 100 supervised cases; proceed only with ≥70% light-edit acceptance, ≥50% handling-time reduction, zero unauthorized L2+ actions or material estimate errors, and fully loaded delivery cost below 20% of measured value; then obtain one outside HVAC contractor at ≥$1,000/month. Stop or redesign after one failed iteration.

Only after that should vertical packs swap intake schemas, price books, compliance rules, terminology, and connectors for plumbing, roofing, electrical, carpentry, or catering. The governed lifecycle, policy kernel, router, approvals, audit trail, and outcome calibration remain constant.

POSITION: Sell one cloud-managed HVAC Estimate Desk on e3d-corp, using Qwen-first typed work and evidence-triggered frontier escalation, with governed L2/L3–4 approvals and hardware deferred until paid residency demand and supportable economics are proven.
status: revise

## Round 3 -- devin

**Two revisions. Core position holds.**

**Revision 1: n8n license — codex is right, and this is material.**

n8n is Sustainable Use License, not MIT. The restriction: you cannot use n8n to provide a commercial service to third parties where n8n is a substantial component. A managed Estimate Desk where n8n orchestrates customer-facing workflows is exactly that use. I was wrong to recommend it even as connector glue. Drop n8n from the stack.

Replacement at the edge: bare Python connector code. For 90 days and one customer, Gmail API + Twilio webhooks + Jobber/HCP REST + QuickBooks read-only is four authenticated HTTP clients, each under 200 lines. No orchestration framework needed. If connector sprawl becomes a problem after the first external contractor, evaluate Apache Airflow (Apache 2.0) or Prefect OSS (Apache 2.0) — both genuinely open, both legal for commercial managed services.

**Revision 2: pgvector timing — concede to grok-build and codex.**

I said build pgvector into the schema week 1 because price-book retrieval requires it. I was wrong about the retrieval mechanism. A price book with structured part numbers and rate codes is a keyword/exact-match lookup, not semantic search. pgvector adds value when the query is "something like the Rheem unit from the Riverside job" — unstructured, memory-based retrieval. That's not week-1 scope. Design the Postgres schema to support a pgvector extension column, but don't activate or index until the first lookup miss shows semantic need. Codex's "only when semantic retrieval proves necessary" is the right sequencing.

**Where my position holds:**

**Against codex on "mobile web approval inbox is sufficient."** Trades contractors are on job sites. Opening a web app to approve a quote draft is three more steps than a phone is already in your hand. SMS one-tap approve/reject is the primary channel. Web inbox is the fallback for RED-level review where you need to see the full diff. This isn't a preference — it's a churn risk. If the approval UX requires a laptop, the contractor stops approving and the workflow stops running.

**Against claude on Temporal.** Claude deferred Temporal but left it as the preference. The e3d-corp event log already persists state between Decision and Action. Adding Temporal means standing up a cluster, a worker pool, and a persistence backend before you have one paying customer. The failure mode for a 90-day pilot is not "approval wait state corruption" — it's "no real ticket volume" and "contractor churns." Temporal does not solve either. Revisit after the first external contractor, not before.

**What all four answers now agree on:**

- e3d-corp as the core runtime (not a new engine)
- One workflow: inbound → cited estimate packet → follow-up queue
- Gmail + Twilio + Jobber/HCP as first connectors; QuickBooks read-only
- Policy kernel: hash-pinned, fail-closed, deterministic, outside model reach
- RED = never autonomous in v1
- Gate: ≥70% acceptance, ≥50% handling-time reduction, zero RED escapes, cost ≤20% of value, one external contractor at ≥$1K/month
- Real ticket volume sourced Day 1 — no simulation
- Hardware waits behind that gate plus demonstrated Qwen-only economics

**Updated stack:** e3d-corp core → bare Python connectors (Gmail, Twilio, Jobber/HCP, QuickBooks) → Postgres + pgvector schema (deferred activation) → SMS approve/reject → hash-pinned policy. No n8n. No Temporal. No vector index until needed.

POSITION: Sell a governed HVAC Estimate Desk as a cloud managed service using e3d-corp as core, bare Python connectors (no n8n), deferred pgvector, and SMS-first approval UX, with real tickets sourced day 1 and one external contractor at ≥$1K/month as the only exit gate.
status: revise

## Round 3 -- grok-build

The remaining disagreements are about the runtime, the price book, and how approvals work. I'll check those against the code before taking a position.My position holds. Two facts from the tree, and one concession to Codex.

`e3d-corp/lib/authority/policy.js` is policy v4. Unknown action types throw. L2 (`send-outreach`) executes on a single approval. L3–4 stay approved and unexecuted until `confirmAndExecute` (`test/phase5.test.js`). Private quote nudges are a new L2 type. Anything that states price, terms, or a booking, plus invoices and public replies, is L3–4. The table is versioned and not hash-pinned: nothing under `lib/` checks a policy hash. Days 1–30 pin those bytes and refuse boot on mismatch. `QwenCodingProvider` is still absent. futco-mcp stays an internal markdown KB.

Concession: the ≥70% Qwen-only figure is an input to later hosting cost, not a service go/no-go. Hardware waits on a paying customer who asks for residency and on local cost beating managed inference.

Devin’s spine is still the wrong build. n8n is Sustainable Use, not MIT, and customer workflows would sit inside a license that restricts offering n8n as the service. Approval state already lives on the proposal. Connectors are small workers that append corp events for Gmail, Twilio recordings, Calendar, and whichever of Housecall Pro or Jobber the first payer uses. `assertProposalAuthorized` stays the only authority. Temporal in these 90 days is a second runtime waiting on states the event log already stores.

A price book is equipment, tonnage, labor hours, and flat rates in Postgres. Devin’s week-1 pgvector, and Claude’s pgvector-by-default, index a catalog that has keys. Vector search starts only after a counted lookup-miss rate on real packets.

The approval surface is the existing proposal screen, as a mobile web inbox. An SMS notifies the owner and deep-links to that proposal, bound to its id and payload hash, with a short expiry. Reply-YES is not an approval. Email links are not an approval. L3–4 still take the separate confirm step. Pre-approved templates are not a standing send grant. A second GPU before the first invoice fights the cost gate. The paid pilot keeps Qwen on the mini, with a written manual fallback when it is down. A second host follows measured downtime or tenant two.

Gates, unchanged: on day 1, if E3D HVAC cannot supply the cases, shadow-read one peer inbox. No simulated tickets. Go only after ≥100 real cases, ≥70% accepted with a light edit, ≥50% less handling time, zero unapproved L2+ sends, and fully loaded cost ≤20% of measured value. Then one outside HVAC contractor at ≥$1,000/month, this workflow only. One miss after one iteration: stop. Intake fields, price book, and compliance lines are the vertical pack, and they wait on that invoice.

Risks, in order: no real tickets; exception labor missing the time and cost gates; one unapproved send; field-service connector sprawl; weak Qwen, which raises frontier spend and still leaves a cloud-assisted service.

POSITION: Sell a cloud-managed HVAC Estimate Desk on e3d-corp’s authority table—one approval for private follow-ups, confirmAndExecute for money and public writes, hash-pin the policy, no Temporal, no vector index, no second workflow—until one contractor pays ≥$1,000/month.
status: revise


## Synthesis (claude)

FINAL ANSWER: Sell one cloud-managed HVAC Estimate Desk (inbound request → cited estimate packet → follow-up queue) built on e3d-corp's existing event loop and authority table. Private follow-ups need one approval (L2). Money, public and binding actions need approval plus a separate confirm (L3–4). Hash-pinning the policy artifact is new build work, since it doesn't exist yet. Connect to the tools the contractor already uses: Gmail/Calendar, Twilio, Jobber or Housecall Pro, and read-only QuickBooks. Use small custom connectors, not n8n, whose license restricts use in a commercial service. Add no Temporal unless a day-1 restart test fails, and no vector index until measured lookup misses appear. Use an authenticated mobile web approval inbox with SMS deep-link notifications.

Source about 100 real cases by day 14, using a peer contractor's inbox if E3D's own HVAC volume is thin. Proceed only if at least 70% of packets are accepted with light edits, handling time drops at least 50%, there are zero unauthorized sends or material errors, and delivery cost is at most 20% of measured value. Then sign one outside contractor at ≥$1,000/month, and stop or redesign after one failed iteration. Hardware waits for paid residency demand and supportable local economics. Other trades come later by swapping the vertical pack (intake fields, price book, compliance lines) while the policy kernel, router, approvals and ledger stay constant.

CONSENSUS: majority

DISSENT: Devin wanted SMS one-tap approval as the primary channel, while the others (and this answer) require an authenticated web inbox with SMS only as notification. Claude also wanted inference moved off the dev Mac mini before the first paid pilot, while grok-build wanted to keep it on the mini with a manual fallback.
