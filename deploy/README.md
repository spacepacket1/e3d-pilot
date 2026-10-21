# Hosted e3d-mcp (remote MCP over HTTP)

This directory builds a container that serves e3d-mcp over streamable HTTP so MCP clients that cannot run local
tools (for example the GitHub Copilot coding agent, which runs on GitHub-hosted runners) can still get a
multi-model debate. **Nothing is deployed anywhere.** No cloud account was used to build or test this, and the
steps for AWS and Azure below are untested notes, not a runbook.

## Build and run locally

```bash
docker build -f deploy/Dockerfile -t e3d-mcp .                                   # ~0.5 GB
docker build -f deploy/Dockerfile --build-arg INSTALL_AWS_CLI=true -t e3d-mcp:aws .   # ~0.85 GB, for the bedrock provider

docker run --rm -p 127.0.0.1:8787:8787 --read-only --tmpfs /tmp -v e3d-mcp-state:/var/lib/e3d-mcp \
  -e E3D_MCP_AUTH_TOKENS="alice:$(openssl rand -hex 24)" \
  -e AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com \
  -e AZURE_OPENAI_DEPLOYMENT=my-deployment \
  -e AZURE_OPENAI_API_KEY=... \
  -e LOCAL_MODEL_ENDPOINT=http://my-inference-host:8000/v1 \
  e3d-mcp
```

The server refuses to start on `0.0.0.0` (the container default) unless `E3D_MCP_AUTH_TOKENS` is set. A client then
sends `Authorization: Bearer <token>` on every request to `POST /mcp`. `GET /healthz` needs no auth and returns only
`{"status":"ok","version":...}`.

The opt-in test `E3D_TEST_DOCKER=1 tests/mcp-container.sh` builds this image and checks: refuses to start without
tokens, runs as the unprivileged `node` user on a read-only filesystem, a full debate against fake Azure/local
endpoints, secrets absent from logs, and the daily budget surviving a container restart.

## What a hosted client can and cannot do

| | Over HTTP |
| --- | --- |
| `e3d_debate`, `e3d_list_providers`, `e3d_usage` | available |
| pipeline tools (`e3d_pilot_*`), `e3d_provenance_trace`, `e3d_ideas_list` | **hidden by default**: they act on repositories on the server's own disk and must not be internet-reachable. `E3D_MCP_HTTP_TOOLS=*` (or a comma list) opts in; think hard before doing that |
| sampling (the client's own models), elicitation (approval prompts), roots | **disabled**: they need server-to-client requests, which this transport does not have. Approvals therefore stay read-only |
| progress notifications | not sent (JSON responses only) |

A tool that is hidden is reported exactly like one that does not exist.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `E3D_MCP_AUTH_TOKENS` | none | **Required beyond loopback.** `name:token,name2:token2`; tokens 16+ characters (`openssl rand -hex 24`). The name is the budget principal. Compared in constant time; never logged. Rotate by changing the variable and restarting (existing sessions end) |
| `E3D_MCP_HOST` / `E3D_MCP_PORT` (or `PORT`) | `0.0.0.0` in the image / `8787` | Listen address |
| `E3D_MCP_DAILY_CALLS` | 100 per principal | Daily model-call cap. `0` = unlimited |
| `E3D_MCP_DAILY_EST_TOKENS` | 500000 per principal | Daily estimated-token cap |
| `E3D_MCP_STATE_DIR` | `/var/lib/e3d-mcp` | Where budgets are stored (mount a volume) |
| `E3D_MCP_HTTP_TOOLS` | `e3d_debate,e3d_list_providers,e3d_usage` | Tool allowlist; `*` = all |
| `E3D_MCP_ALLOWED_ORIGINS` | none | Browser `Origin`s allowed (comma list). Requests with no `Origin` (non-browser clients) are always fine; any other `Origin` is a 403 |
| `E3D_MCP_RATE_PER_MIN` | 60 | Requests per principal per minute (429 + `Retry-After`) |
| `E3D_MCP_MAX_BODY_BYTES` | 262144 | Request body cap (413) |
| `E3D_MCP_HTTP_MAX_INFLIGHT` | 16 | Concurrent requests (503) |
| `E3D_MCP_MAX_SESSIONS` / `E3D_MCP_SESSION_TTL_SEC` | 1000 / 3600 | Session cap and idle expiry |
| `E3D_MCP_TIMEOUT_SEC` | 120 (hosted) | Per-debate timeout; kept low to fit load-balancer timeouts |
| `E3D_MCP_HTTP_REQUEST_TIMEOUT_SEC` | 900 | Per-request ceiling (504) |
| `E3D_MCP_PROVIDERS` / `E3D_MCP_AUTO_VOICES` | auto | Pin or cap the debate voices |
| model providers | | `AZURE_OPENAI_ENDPOINT/_DEPLOYMENT/_API_KEY[_FILE]`, `BEDROCK_MODEL_ID` + `AWS_REGION` (+ AWS credentials), `LOCAL_MODEL_ENDPOINT/_NAME`, `ANTHROPIC_API_KEY[_FILE]`/`ANTHROPIC_API_MODEL`, `OPENAI_API_KEY[_FILE]`/`OPENAI_API_MODEL`, `GEMINI_API_KEY[_FILE]`/`GEMINI_API_MODEL`, `XAI_API_KEY[_FILE]`/`XAI_API_MODEL`; see the main README's Providers section |

## Budgets and who pays

Every debate spends **the operator's** provider credentials (the Azure key, the AWS role, the local endpoint), not
the caller's. The only protection is the per-principal daily budget: model calls and *estimated* tokens (characters /
4), counted from each debate's transcript, checked against the worst case **before** a debate starts and recorded
afterwards, resetting at 00:00 UTC. `e3d_debate` results include `usage` and `budget`; `e3d_usage` shows both.

Things this does **not** give you:

- **No global cap.** Caps are per token name, so ten names each get their own budget. Size the number of tokens accordingly.
- **State is local to one instance.** Budgets live in files on the volume, written atomically but not locked across processes. Run **one replica** per state volume; scaling out multiplies the budget and can race.
- **Tokens are shared secrets, not user identities.** There is no OAuth, per-user login, or revocation list beyond restarting with a new variable.
- Token counts are estimates and can be off by a lot; the call cap is the sturdier limit.

## Providers inside the container

The image has no `claude`/`codex` CLIs. A debate needs **at least two distinct providers** from `anthropic-api`,
`openai-api`, `azure-openai`, `bedrock` (build with `INSTALL_AWS_CLI=true`) and `local`. The simplest hosted setup
is `anthropic-api` plus `openai-api`, which only need keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and
`OPENAI_API_MODEL`; use `*_API_KEY_FILE` with a mounted secret instead of putting keys in the environment). A
deployment with only one Azure deployment or one Bedrock model still cannot debate, because there is one slot per
adapter. Pin the voices with `E3D_MCP_PROVIDERS=anthropic-api,openai-api`.

## Putting it on a cloud (untested notes)

TLS must be terminated in front of the container (the server speaks plain HTTP). Keep a single replica.

- **AWS**: ECS/Fargate or App Runner behind an Application Load Balancer with an ACM certificate. For Bedrock, give the task role `bedrock:InvokeModel` and let the AWS credential chain pick it up (no keys in the environment). Put `E3D_MCP_AUTH_TOKENS` and API keys in Secrets Manager. The ALB's idle timeout defaults to 60 s, shorter than the 120 s default debate timeout; raise it, or stay on `quick` mode.
- **Azure**: Container Apps with external ingress (TLS is provided by the platform). Store tokens and `AZURE_OPENAI_API_KEY` as secrets. The adapter authenticates with an API key; it does not use managed identity or Entra tokens. Check the ingress request timeout against your debate timeout.
- Either: mount persistent storage at `/var/lib/e3d-mcp` or accept that budgets reset when the container is replaced.
