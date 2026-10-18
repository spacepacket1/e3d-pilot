CONTEXT
e3d-brain is a small, local-first memory server. It sits over a plain folder of Markdown files (an Obsidian vault), speaks MCP, and gives Claude and the E3D agents continuity across sessions. A second layer, cognition, looks after the memory: it notices what was superseded, duplicated or stale, and what real outcomes taught, and it proposes changes for a human to accept. It is open source (MIT) and deliberately small. Its specs are docs/e3d-brain-spec.md and docs/e3d-brain-cognition-spec.md.

The document below is a provisional "Living Idea" from an Obsidian vault (Joel Do(OS), IteraWorks, Growlocity). It proposes that personal and organizational intelligence systems stay independently governed but interoperable ("federated"), with selective sharing across boundaries. It links to other vault notes that are not provided here, so judge it on what is written.

QUESTION
Decide how, and whether, this document should be included in e3d-brain. Answer each point:
1. VERDICT. Pick exactly one: (a) adopt it as a design requirement in the specs; (b) include it as an ideas/design note in docs/ without committing to build; (c) defer it with a stated trigger for revisiting; (d) do not include it. Justify the pick in a few sentences.
2. WHAT HOLDS UP. Which claims are sound and useful? Which are unproven, hand-wavy, or restate well-known work (access control, multi-tenancy, attribute-based policy, capability-style sharing)? What is genuinely new, if anything?
3. IMPLICATIONS FOR e3d-brain. What would have to change if it were adopted (data model, frontmatter fields such as origin / relevance / visibility / authority, MCP tools, the cognition layer)? What is the smallest slice worth building now, and what should wait?
4. RISKS. Privacy and boundary leaks, complexity, scope creep for a small local-first server, anything that conflicts with its current design.
5. EDITS. What would you cut, rename, or clarify in the document itself before it is included?
Be decisive and specific, and end with one recommended next action.

DOCUMENT
---
title: Federated Personal & Organizational Intelligence
artifact_type: Living Idea
date_created: 2026-09-25
date_updated: 2026-09-25
status: provisional
release_maturity: provisional
origin:
  - "[[2026-09-25 Compare LLM Wiki Obsidian Distillation]]"
source_ice:
  - "[[2026-09-25 Compare LLM Wiki Obsidian ICE]]"
governed_by:
  - "[[00 Joel Do(OS) Constitution v1.0 (Stable)]]"
  - "[[02 Conversation Ingestion Pipeline (CIP) Specification v1.2]]"
domains:
  - InnerSpacial OS
  - Joel Do(OS)
  - IteraWorks
  - Growlocity
themes:
  - personal operating systems
  - organizational operating systems
  - federated intelligence
  - information sovereignty
  - knowledge boundaries
  - selective sharing
  - multi-context knowledge
  - organizational intelligence
related_documents:
  - "[[2026-09-25 Ambient Intelligence & Convergence Living Idea]]"
  - "[[2026-09-25 JEEVIS & Federated Human-AI Governance Living Idea]]"
---

# Federated Personal & Organizational Intelligence

## Living Idea

Personal and organizational intelligence systems should remain **independently governed but interoperable**.

A human should not need to expose a private Personal OS in order to participate fully in an organizational intelligence system.

Likewise, an organization should not depend on fragmented private knowledge that only exists inside the minds, files, or personal AI systems of individual members.

The emerging model is therefore **federated**:

- each person retains a sovereign personal intelligence environment,
- each organization maintains its own shared intelligence environment,
- knowledge crosses boundaries selectively,
- relevance may span several domains simultaneously,
- AI mediates context exchange according to explicit permissions and policies.

The objective is not to create one universal shared brain.

It is to create **interoperable intelligence systems with preserved boundaries**.

---

## Core Distinction

A Personal OS and a Group OS answer different questions.

### Personal OS

A Personal OS answers:

> What does this person know, believe, notice, intend, value, and want to preserve?

It may include:

- private thinking
- personal strategy
- life priorities
- learning
- finances
- health
- creative work
- personal reflections
- business thinking not ready for disclosure
- cross-project synthesis
- personal interpretations of shared events

### Group OS

A Group OS answers:

> What does this organization collectively know, believe, decide, test, intend, and need to coordinate?

It may include:

- strategy
- decisions
- experiments
- customer learning
- project state
- operating principles
- shared research
- organizational hypotheses
- roles and responsibilities
- meeting outcomes
- product knowledge
- lessons learned
- canonical organizational knowledge

The two systems may overlap heavily in subject matter while remaining different in **authority, meaning, visibility, and ownership**.

---

## Federation Rather Than Merger

The Group OS should not be created by merging the private systems of its members.

A merged architecture would create unacceptable privacy, governance, and ownership problems.

Instead:

```text
Personal OS A ──┐
                │
Personal OS B ──┼── selective contribution ──► Group OS
                │
Personal OS C ──┘
```

Each Personal OS remains sovereign.

The Group OS receives knowledge that is intentionally shared, created in shared settings, or published according to agreed policy.

The organization does **not** inherit the access privileges of the individual.

This leads to a durable principle:

> **Agents may query across authorized boundaries. Knowledge crosses boundaries only according to policy.**

---

## Information Sovereignty

A person's AI may be authorized to query both private and shared systems because it acts on behalf of that person.

The organization itself should not automatically receive reciprocal access.

For example:

```text
Joel's JEEVIS
    │
    ├── Joel Do(OS)
    ├── IteraWorks OS
    ├── Growlocity OS
    └── authorized external systems
```

But:

```text
IteraWorks OS
    ✕── unrestricted access to Joel Do(OS)
```

This distinction establishes **information sovereignty**.

A Personal OS belongs to the individual.

A Group OS belongs to, or is collectively governed by, the organization.

Shared intelligence should emerge through explicit exchange rather than invisible inheritance of private context.

---

## Classification Is Not Sharing

An important boundary is:

> **Relevance does not imply disclosure.**

A private system may determine that a conversation is relevant to IteraWorks, Growlocity, or another group.

That classification alone should not cause the source material to cross the boundary.

Instead:

```text
private activity
      ↓
AI detects organizational relevance
      ↓
private contribution candidate
      ↓
policy / approval
      ↓
sanitized or contextualized contribution
      ↓
Group OS
```

The candidate layer may remain private indefinitely.

This allows AI to be aggressive in recognizing relevance without being aggressive in disclosure.

---

## Contributions Should Be Knowledge Objects, Not Vault Access

Cross-boundary sharing should ideally occur through a defined contribution object rather than through wholesale file copying or direct private-vault access.

A contribution might contain properties such as:

```yaml
contributor: Joel
destination: IteraWorks
source_domain: Personal OS
type: insight
status: provisional
sharing: approved
provenance: preserved
date: 2026-09-25
```

The Group OS can then:

- ingest the contribution,
- connect it,
- compare it with other knowledge,
- detect convergence,
- preserve provenance,
- surface contradictions,
- recommend promotion into canonical organizational knowledge.

The private source material does not need to cross the boundary unless intentionally included.

---

## Origin, Relevance, Visibility, and Authority Are Separate

Traditional systems often collapse several properties into one.

This architecture should keep them distinct.

An item can have:

- **origin** — where the event or idea occurred,
- **relevance** — which domains it connects to,
- **visibility** — who may see it,
- **authority** — whether it is canonical, provisional, inferred, or ambient.

For example:

```yaml
origin: personal
relevant_to:
  - personal
  - IteraWorks
visibility:
  - Joel
authority: provisional
```

Or:

```yaml
origin: IteraWorks
relevant_to:
  - IteraWorks
  - personal
  - Growlocity
visibility:
  - IteraWorks members
  - Joel
authority: canonical-organizational
```

This prevents false assumptions such as:

> “Because it happened at IteraWorks, it belongs only to IteraWorks.”

or:

> “Because it is relevant to IteraWorks, IteraWorks should automatically see it.”

---

## Knowledge Should Be Multi-Contextual

Joel's work is inherently multi-duty.

One activity may simultaneously advance:

- Joel Do(OS),
- IteraWorks,
- Growlocity,
- AI capability,
- Life Flywheel,
- future opportunity development.

The architecture should not force one exclusive filing location.

Instead, one event or knowledge object may participate in several contexts.

A candidate design principle is:

> **Knowledge should be natively multi-contextual, not forcibly single-homed.**

This is not duplication for duplication's sake.

Different systems may legitimately hold different **projections** of the same underlying event.

---

## Same Event, Different Meaning

A single real-world event may produce distinct but valid organizational and personal interpretations.

Example:

```text
SOURCE EVENT
"IteraWorks agrees to test an AI-native knowledge-system POC"
          │
     ┌────┴────┐
     ▼         ▼
IteraWorks OS  Joel Do(OS)
```

The IteraWorks version may emphasize:

- team decision,
- scope,
- milestones,
- owners,
- risks,
- shared rationale.

The Joel Do(OS) version may emphasize:

- Life Flywheel implications,
- learning value,
- career impact,
- opportunity relationships,
- personal interpretation.

These are not redundant copies serving the same purpose.

They are **different contextualizations of the same reality**.

---

## Personal Activity Stream and Scoped Projections

A useful conceptual model is:

> **Capture once. Classify afterward. Publish into one or more domains according to relevance, visibility, and policy.**

Rather than maintaining separate ambient recorders for each domain, a personal activity stream can be analyzed once and projected into multiple knowledge domains where appropriate.

For example:

```yaml
domains:
  - personal
  - IteraWorks
  - Growlocity

primary_domain: IteraWorks

relevance:
  personal: high
  IteraWorks: high
  Growlocity: medium
```

This better reflects how multi-duty work actually occurs.

Ambiguity should be allowed.

The system does not need to force one definitive answer when reality is genuinely overlapping.

---

## Group Ambient and Group Canonical Knowledge

A Group OS may ultimately require the same two-layer distinction emerging within the Personal OS.

### Organizational Ambient Knowledge

May include:

- meeting transcripts,
- informal hypotheses,
- early ideas,
- research fragments,
- conversations,
- provisional interpretations,
- weak signals,
- unresolved disagreements,
- potential opportunities.

### Organizational Canonical Knowledge

May include:

- approved strategy,
- decisions,
- active specifications,
- agreed operating principles,
- confirmed project state,
- official organizational positions.

The promotion flow may resemble:

```text
ambient team knowledge
        ↓
pattern / convergence / evidence
        ↓
candidate insight
        ↓
human discussion
        ↓
approval
        ↓
canonical organizational knowledge
```

This preserves the same human-governance philosophy at organizational scale.

---

## Organizational Intelligence Rather Than Knowledge Base

The Group OS should not simply recreate a traditional company knowledge base in a more modern interface.

Traditional knowledge bases often deteriorate because humans must continually manage:

- folders,
- filenames,
- versions,
- duplication,
- superseded material,
- relationships,
- ownership,
- relevance,
- departed employees' knowledge.

An AI-native Group OS changes the assumption.

Humans produce work and experience.

AI may increasingly maintain the knowledge topology.

The system should aim to answer:

> **What does this organization know?**

and eventually:

> **What is this organization learning?**

rather than merely:

> **Where is the information?**

---

## Cross-Boundary Convergence

Federated architecture enables several levels of convergence.

### Personal Convergence

A Personal OS may detect that several parts of a person's life or work are moving toward the same idea.

That insight remains private unless shared.

### Organizational Convergence

A Group OS may recognize that contributions from several members independently support the same opportunity, risk, or design direction.

### Cross-Boundary Convergence

A personal AI may detect that organizational activity strongly aligns with something in the person's private system.

The organization does not need access to the private half of that convergence.

This is an important privacy property.

The insight can remain personal while still improving the person's decisions.

---

## Relationship to Ambient Intelligence & Convergence

[[Ambient Intelligence & Convergence]] provides the machine-maintained layer that can preserve weak signals and detect emerging relationships.

Federated Personal & Organizational Intelligence defines **where that intelligence may live, who owns it, and how it may cross boundaries**.

The two ideas therefore solve different problems:

- Ambient Intelligence asks: **What might be worth remembering or connecting?**
- Federated Intelligence asks: **Who may know, use, or receive it?**

---

## Relationship to JEEVIS

A future JEEVIS is a likely mediator between these domains.

For Joel, JEEVIS may combine:

```text
Group Knowledge
+
Joel Private Knowledge
+
Current Task
=
Personalized Execution
```

Another member's AI may perform the same operation with different private context:

```text
Group Knowledge
+
Partner Private Knowledge
+
Current Task
=
Partner-Specific Execution
```

Thus everyone can benefit from the same organizational substrate without becoming cognitively identical.

This preserves individual perspective while increasing collective intelligence.

---

## Relationship to Life Flywheel

The Life Flywheel values activities that serve multiple purposes simultaneously.

Federated and multi-context knowledge architecture provides a potential way to capture those overlapping effects without requiring each activity to be manually filed into a single domain.

The Flywheel describes the value of multi-duty activity.

This Living Idea begins to describe the **information architecture that can support it**.

---

## IteraWorks as a Potential POC Environment

IteraWorks may eventually provide a useful small-scale test environment because it has:

- a small number of human participants,
- meaningful shared business activity,
- likely private intelligence systems,
- overlapping personal and organizational interests,
- a need for shared learning,
- enough complexity to test boundaries without enterprise-scale overhead.

A future POC might test:

- private Personal OSes,
- one shared Group OS,
- contribution objects,
- sharing approval,
- group ambient memory,
- group canonical knowledge,
- cross-member convergence,
- provenance,
- privacy boundaries.

This Living Idea does **not** assert that IteraWorks has adopted such a POC.

It identifies IteraWorks only as a potentially valuable test environment.

---

## Candidate Design Principles

The following principles emerged from the originating inquiry and remain provisional:

> **Personal intelligence systems should remain sovereign.**

> **Classification does not imply disclosure.**

> **Knowledge should be natively multi-contextual, not forcibly single-homed.**

> **Agents may query across authorized boundaries. Knowledge crosses boundaries only according to policy.**

> **Capture broadly. Classify multiply. Infer autonomously. Share selectively. Govern deliberately.**

These should accumulate operational evidence before consideration for promotion into stable InnerSpacial OS architecture.

---

## Open Questions

- What is the minimum viable Group OS?
- Which organizational events should enter group ambient memory automatically?
- How should private contribution candidates be surfaced?
- Which contribution types may eventually be auto-approved?
- How should revocation or retraction work after knowledge has been shared?
- How should conflicting contributions from multiple members be represented?
- How should intellectual ownership be preserved?
- What happens when someone leaves an organization?
- Which organizational knowledge should remain accessible to former members?
- What should be canonical at the group level versus personal level?
- How should one event generate multiple domain-specific projections?
- How should provenance survive transformation across OS boundaries?
- How should a Group OS distinguish organizational consensus from one person's opinion?
- How should permissions work when one person belongs to several organizations?
- Can shared AI systems detect convergence without exposing underlying private evidence?
- What governance model is needed before personal AIs begin negotiating or acting across boundaries?

---

## Current Status

**Provisional Living Idea.**

The architectural direction appears coherent and highly compatible with existing Joel Do(OS) governance philosophy, but the mechanisms for contribution, permissions, projections, Group OS operation, and cross-boundary AI behavior remain unvalidated.

No changes to the Constitution, Architecture Specification, CIP, or existing project notes are implied by this Living Idea.

