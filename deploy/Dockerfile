# syntax=docker/dockerfile:1
#
# Hosted/remote e3d-mcp (streamable HTTP). Build from the repository root:
#   docker build -f deploy/Dockerfile -t e3d-mcp .
#   docker build -f deploy/Dockerfile --build-arg INSTALL_AWS_CLI=true -t e3d-mcp:aws .   # for the bedrock provider
#
# Cloud-agnostic: the same image runs on AWS (ECS/Fargate, App Runner), Azure (Container Apps) or anywhere
# else that runs containers. TLS is NOT terminated here; put a load balancer or reverse proxy in front.
ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-bookworm-slim

# bash 5 (bookworm), jq, curl and git are what the provider adapters and the CLI use.
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash jq git curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*

# Optional AWS CLI v2 (needed only for the `bedrock` provider). Picks the right build for the CPU.
ARG INSTALL_AWS_CLI=false
RUN if [ "$INSTALL_AWS_CLI" = "true" ]; then \
      arch="$(uname -m)"; \
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o /tmp/awscliv2.zip \
   && unzip -q /tmp/awscliv2.zip -d /tmp \
   && /tmp/aws/install \
   && rm -rf /tmp/aws /tmp/awscliv2.zip; \
    fi

WORKDIR /opt/e3d-pilot
COPY package.json LICENSE config.schema.json ./
COPY bin ./bin
COPY lib ./lib

# State (usage budgets) lives on a volume so it survives restarts; everything else can be read-only.
ENV E3D_MCP_STATE_DIR=/var/lib/e3d-mcp \
    E3D_MCP_HOST=0.0.0.0 \
    E3D_MCP_PORT=8787 \
    TMPDIR=/tmp \
    HOME=/home/node \
    NODE_ENV=production
RUN mkdir -p /var/lib/e3d-mcp && chown -R node:node /var/lib/e3d-mcp
VOLUME ["/var/lib/e3d-mcp"]

USER node
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.E3D_MCP_PORT||8787)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Refuses to start on 0.0.0.0 unless E3D_MCP_AUTH_TOKENS is set (by design).
ENTRYPOINT ["node", "/opt/e3d-pilot/bin/e3d-mcp", "--http"]
