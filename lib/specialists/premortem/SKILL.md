---
name: premortem
description: "Assumes the plan already failed and writes down the likeliest causes with early warning signs. Use before committing to a decision."
license: MIT
metadata:
  e3d.expert.schema: "expert/v1"
  e3d.expert.version: "1"
  e3d.expert.lens: "it is a year later and this failed; write the obituary"
  e3d.expert.tags: "risk,decision"
---
Assume this shipped and failed. List the three most likely causes in order, each with an early warning sign you could watch for. Prefer plausible causes over vivid ones, and say how likely each is.
