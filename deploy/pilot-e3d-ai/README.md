# pilot.e3d.ai: the hosted debate service on the existing e3d.ai server

Hosts `e3d-mcp --http` (see `../README.md`) at **https://pilot.e3d.ai/mcp** behind the server's existing nginx. Only
`e3d_debate`, `e3d_list_providers` and `e3d_usage` are exposed. Nothing in this kit has been run on the real
server yet; the application half was run locally (see "What was tested").

## How it is laid out, and why

| Piece | Choice | Reason |
| --- | --- | --- |
| DNS | `A pilot.e3d.ai -> 3.131.8.46`, **DNS-only** (grey cloud) | Cloudflare's proxy cuts requests at about 100 seconds; `mcp.e3d.ai` is set up the same way |
| TLS | Let's Encrypt via `certbot --nginx` | already how e3d.ai does it |
| Process | systemd service, dedicated `e3dpilot` user | the box also runs production sites |
| Isolation | read-only code, write access only to `/var/lib/e3d-mcp`, private `/tmp`, `MemoryMax=768M`, `CPUQuota=60%` | a bug or abusive caller cannot hurt the other sites |
| Listen | `127.0.0.1:8787` only | nginx is the only way in |
| nginx | rate limit 20 requests/min per IP, 64 KB body cap, only `/mcp` and `/healthz` proxied (everything else is 404) | defense in depth |
| App | bearer tokens, per-token daily call and token budgets, origin checks | see `../README.md` |
| Models | `anthropic-api` and `openai-api` (your own keys) | two distinct providers are needed for a debate |

## Order of operations

1. **Code on GitHub.** The server clones the repo, so `main` must contain the hosted transport. (As of this writing the hosted
   transport is on the local `main` only; push first.)
2. **DNS** (from your Mac): `./cf-dns.sh create`, then `./cf-dns.sh status`. Undo with `./cf-dns.sh delete`.
3. **On the server**, as root: `sudo REF=main CERTBOT_EMAIL=you@example.com bash install.sh`. It prints three access tokens once.
4. Edit `/etc/e3d-mcp/pilot.env`: replace the three `__PASTE_...__` values (Anthropic key, OpenAI key, OpenAI model name), then
   `sudo systemctl enable --now e3d-mcp`.
5. **Verify** from your Mac: `./verify.sh https://pilot.e3d.ai <token>` (add `--debate` for one real quick debate, a few cents).

## Spending limits

Node: e3d-mcp runs its child scripts with the directory of its own node first on PATH, so `@NODE@` (an absolute Node 18+ path) is also what `bin/e3d-debate` uses. On releases before this behavior, add `PATH=<node dir>:/usr/local/bin:/usr/bin:/bin` to `pilot.env`, or the sandbox may resolve `node` to an old `/usr/bin/node` and silently turn web search off. After a deploy, `e3d-mcp --doctor` shows the node used by children and whether `websearch.mjs config` runs.

Defaults in `pilot.env.example`: per token name, **20 model calls and 150,000 estimated tokens per day**, 10 requests/minute.
A quick debate is 3 calls, so a token can run about 6 quick debates a day. There is **no global cap**: three tokens means three
budgets. Keep the list short, and watch the provider dashboards for the first week, because the token counts are estimates.

## Day-two operations

- Logs: `journalctl -u e3d-mcp -f` (tokens and keys are redacted by the server).
- Add, remove or rotate a token: edit `E3D_MCP_AUTH_TOKENS` in the env file, `sudo systemctl restart e3d-mcp`. There is no per-user login or revocation list.
- Update the code: re-run `install.sh` (it fetches `REF`, leaves `pilot.env` alone) then `sudo systemctl restart e3d-mcp`.
- Roll back: `sudo systemctl disable --now e3d-mcp`, remove `/etc/nginx/sites-enabled/pilot.e3d.ai`, `sudo nginx -s reload`, `./cf-dns.sh delete`.

## What was tested, and what was not

Tested locally: the service in hosted mode (loopback, token auth, budgets) through `verify.sh`, including a real quick
debate in 9 seconds (3 model calls) and a check that the token never reaches the server log; the DNS script's read-only `status`.

**Not tested:** `install.sh`, the systemd unit, the nginx site and certbot (nobody has run them on that server), the
`cf-dns.sh create` write path, the OpenAI provider with a real key, and behavior under real traffic.
