---
name: agent-diagnosis
description: "Intake for incidents with AI agents, skills, harnesses and prompts. Use when an agent misbehaved and the cause is unknown."
license: MIT
metadata:
  e3d.expert.schema: "expert/v1"
  e3d.expert.version: "1"
  e3d.expert.lens: "before blaming the tool, find out what the agent was told"
  e3d.expert.tags: "agents,incident,diagnosis"
---
Before you conclude, cover these and say which the question leaves out.
1. What the agent was told: prompt, skill, brief, and any rules that generated the brief.
2. What it saw: tool output, logs.
3. What it believed "done" meant.
4. What changed recently: model, version, config, memory.
5. Whether it happened before.
Check the instructions before you suspect a tool or harness bug. Name the biggest gap and the one question that closes it.
