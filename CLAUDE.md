# e3d-pilot

Open source (public repo). Multi-model debate engine and MCP server: `bin/e3d-debate` (standalone debate), `bin/e3d-mcp` (MCP server, local and hosted), `bin/e3d-pilot` (the idea-to-PR pipeline). Provider adapters are in `lib/providers/<name>`. The hosted service at pilot.e3d.ai runs this engine behind a metering layer; nothing about its servers, hostnames, keys or internal pricing belongs in this repo.

## Commands

```
for f in tests/*.sh; do bash "$f"; done      # whole suite (the README's own line); run one with: bash tests/<name>.sh
bash tests/verdict-parse.sh                  # synthesizer verdict parsing (lib/mcp/verdict.js)
bash tests/debate-prompts.sh                 # prompt wording
E3D_DEBATE_PROMPT_OVERHEAD=1 bin/e3d-debate "x" --providers anthropic-api,openai-api,gemini-api,xai-api --rounds 1
```

Tests use fake providers and fake local servers; they do not call real vendors. Run the tests for the area you touched plus `tests/mcp.sh`, `tests/engine-node.sh` and `tests/seat-reliability.sh` for anything in `bin/e3d-debate` or `lib/mcp/`.

## Rules that are easy to break

- **Prompt text is priced.** The hosting service sizes its quote from the fixed byte count of each prompt, so a wording change to a prompt in `bin/e3d-debate` must be re-measured with the overhead command above, and the PR must state the new sizes. The default prompt version is `v2`.
- **The synthesizer has a small output budget.** The verdict format is `FINAL ANSWER` then `CONSENSUS` then `DISSENT`, kept short on purpose (answer at most 60 words, dissent at most 40). `lib/mcp/verdict.js` keeps whatever part of a cut-short reply arrived and never invents the rest. Do not lengthen the format without raising the quoted output limit.
- **Never put a real key in a command line, a log, a test fixture or a commit.** Adapters read keys from the environment or mode-0600 files. Check a key file's format before sourcing it (some hold the raw key, not `NAME=value`).
- **Per-token mode** (`E3D_DEBATE_MAX_TOKENS` and friends) is how the hosted service bounds cost: every call carries an output limit and usage is reported per call. Keep new provider calls inside it.
- When running `bin/e3d-debate` for a decision on this project, pass `--repo <path> --idea <id>` together with `--out-dir` inside the repo so the debate links into the provenance graph.
- Keep `README.md` claims true: if the README says a mode is tested, a test must cover it.

## Working agreements

Branch and worktree per change, small PRs, squash merge, no force-push to main, no `--admin`. Commit messages say what changed and why in plain words. Public repo: no private partner or compensation terms, no internal URLs, no customer data.

## Mac gotchas

No `timeout` (use `perl -e 'alarm N; exec @ARGV'`); `sed -i ''`; zsh errors on unmatched globs.
