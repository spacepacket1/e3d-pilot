---
name: review
description: Review staged changes for correctness, security, and style issues
allowed-tools:
  - read
  - grep
  - glob
  - exec
permissions:
  allow:
    - Exec(git diff)
    - Exec(git log)
    - Exec(git status)
---

Run `git diff --staged` and review the changes thoroughly.

Evaluate:
1. **Correctness** — Logic errors, edge cases, or broken invariants?
2. **Security** — Any vulnerabilities introduced?
3. **Performance** — Obvious inefficiencies?
4. **Style** — Consistent with the surrounding codebase?
5. **Tests** — Are new behaviours covered?

Provide a concise summary with specific file + line references for any issues.
