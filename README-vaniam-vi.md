# OpenClaw — vaniam-ai Deployment Guide

This document covers everything you need to understand, deploy, and operate the OpenClaw gateway on the `vaniam-ai` branch using AWS Lightsail with AWS Bedrock as the AI provider and Slack as the messaging channel.

---

## What Is OpenClaw?

OpenClaw is a self-hosted, multi-channel AI assistant gateway. You run it on your own infrastructure, connect it to the AI providers you choose, and interact with it through the messaging channels you already use — Slack, Telegram, WhatsApp, Discord, Signal, iMessage, and many more.

The gateway is the control plane: it handles routing, authentication, agent execution, tool use, and channel-specific integrations. Everything runs behind a single authenticated endpoint that you control.

**Why self-hosted?** Your data, your keys, your costs. No vendor lock-in at the infrastructure layer. The gateway persists conversation state, workspace data, and configuration to your own disk — nothing is stored on a third-party platform unless you explicitly connect one.

---

## The vaniam-ai Branch

The `vaniam-ai` branch is a deployment configuration targeting AWS Lightsail. It uses:

- **AWS Lightsail Instance** (Ubuntu 22.04) as the runtime host — a persistent VM with a 160 GB SSD that survives redeploys
- **AWS Bedrock** as the AI provider (Anthropic Claude models via managed API, no direct Anthropic key needed)
- **Slack** as the primary messaging channel (Socket Mode — no public webhook URL required)
- **GitHub Actions** for CI/CD — every push to `vaniam-ai` builds a Docker image, pushes it to GHCR, and deploys it to the instance over SSH
- **Terraform** (in `infra/`) for reproducible AWS infrastructure provisioning

### Why Lightsail Instance and not Lightsail Container Service?

Lightsail Container Service has no persistent volume support. The gateway stores all state — configuration, sessions, workspace data — in `~/.openclaw/` and that state must survive redeploys. A Lightsail Instance gives a persistent SSD that lives as long as the instance does. The application itself still runs in Docker on that VM, giving reproducible builds without building on the instance and easy rollbacks via image tags.

---

## Architecture

```
Internet (HTTPS 443)
        │
        ▼
Lightsail Load Balancer  ──── SSL termination (Let's Encrypt via your domain)
        │
        ▼  HTTP :18789
Lightsail Instance  (Ubuntu 22.04, 4 vCPU, 8 GB RAM, 160 GB SSD — $40/mo)
  ├── Docker Engine
  │     └── openclaw-gateway container
  │           image : ghcr.io/<owner>/<repo>:vaniam-ai
  │           port  : 18789
  │           volume: /opt/openclaw/state → /home/node/.openclaw  (persists on SSD)
  └── Static IP (free when attached)

GitHub Actions (push to vaniam-ai)
  1. docker build → ghcr.io/<owner>/<repo>:<sha> + :vaniam-ai
  2. SSH → docker compose pull && up -d → /healthz check
```

### Request Flow

1. Client (Slack bot / browser / CLI) connects to `https://openclaw.yourdomain.com`
2. Load balancer terminates TLS and forwards plain HTTP to port `18789` on the instance
3. Gateway authenticates the request via `OPENCLAW_GATEWAY_TOKEN`
4. Gateway routes to the appropriate channel handler (Slack, web UI, etc.)
5. Agent executes using the configured Bedrock model
6. Response is delivered back through the originating channel

### Persistent State

All persistent data lives in `/opt/openclaw/state` on the instance SSD, bind-mounted into the container at `/home/node/.openclaw`. This includes:

| Path (inside container) | Contents |
|---|---|
| `/home/node/.openclaw/openclaw.json` | Gateway configuration |
| `/home/node/.openclaw/sessions/` | Agent session history |
| `/home/node/.openclaw/workspace/` | Agent workspace files |
| `/home/node/.openclaw/credentials/` | Channel credentials |

This data persists across container restarts, image updates, and redeploys. It does **not** survive instance deletion — take snapshots before destructive operations (see [Backup](#backup-state)).

---

## Cost Estimate

| Resource | Plan | $/mo |
|---|---|---|
| Lightsail Instance | 4 vCPU / 8 GB / 160 GB SSD | $40 |
| Lightsail Load Balancer | 1 LB (SSL included) | $18 |
| Static IP | Attached to instance | $0 |
| Data transfer | 5 TB included | $0 |
| **Total** | | **~$58** |

GHCR is free for public repositories. Bedrock costs are pay-per-token on top of this.

---

## Prerequisites

Collect these before starting:

- [ ] AWS account with billing enabled
- [ ] A domain name you control (required for LB SSL via Let's Encrypt)
- [ ] AWS Bedrock model access enabled in `us-east-1` — AWS Console → Bedrock → Model access → enable **Claude 3.5 Sonnet** and **Claude 3.5 Haiku**
- [ ] A Slack app with bot + Socket Mode tokens (see [Slack Setup](#phase-3--slack-app-setup))
- [ ] GitHub account with write access to this repository
- [ ] Terraform ≥ 1.6 installed locally (`brew install terraform`)
- [ ] AWS CLI configured locally (`aws configure`)

---

## Repository Layout

```
.
├── src/                        Core TypeScript source
│   ├── gateway/                Gateway server, auth, WebSocket RPC
│   ├── channels/               Messaging channel integrations
│   ├── agents/                 Agent framework and tool execution
│   ├── cli/                    CLI commands
│   ├── commands/               Command implementations
│   ├── config/                 Configuration schema and parsing
│   └── plugin-sdk/             Public plugin contract surface
├── extensions/                 Bundled workspace plugins
├── apps/                       Platform apps (macOS, iOS, Android)
├── ui/                         Web UI (control panel, WebChat)
├── infra/                      Terraform for AWS Lightsail deployment
│   ├── main.tf                 Provider configuration
│   ├── variables.tf            Input variables
│   ├── lightsail_instance.tf   VM, static IP, firewall, bootstrap script
│   ├── lightsail_lb.tf         Load balancer, SSL cert, HTTPS redirect
│   ├── iam.tf                  Bedrock IAM user, policy, access key
│   └── outputs.tf              Static IP, LB DNS, cert validation records
├── SPECS/
│   └── aws_lightsail_deployment_SPEC.md  Full deployment specification
├── .github/workflows/
│   ├── deploy-lightsail.yml    CI/CD pipeline for this branch
│   └── ...                     Other CI workflows
├── Dockerfile                  Multi-stage production image
├── docker-compose.yml          Local development compose
└── package.json                Root package (pnpm workspaces)
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Runtime | Node.js 24 (min 22.16) |
| Language | TypeScript (compiled to `dist/`) |
| Package manager | pnpm workspaces |
| Gateway framework | Express.js 5 + WebSockets (ws) |
| AI providers | AWS Bedrock, Anthropic, OpenAI, Google GenAI, Ollama |
| Channels | Slack, Telegram, Discord, WhatsApp, Signal, iMessage, Matrix, + more |
| Containers | Docker (multi-stage), Docker Compose |
| Infrastructure | AWS Lightsail, Terraform ≥ 1.6 |
| CI/CD | GitHub Actions → GHCR |

---

## Phase 1 — Provision AWS Infrastructure with Terraform

The `infra/` directory contains all Terraform needed for the Lightsail deployment.

### Required input

You must supply your domain name. Everything else has sensible defaults.

### Run

```bash
cd infra
terraform init
terraform apply -var="domain_name=openclaw.yourdomain.com"
```

This creates:
- Lightsail instance (`openclaw-vaniam`) with Docker pre-installed via user-data
- Static IP attached to the instance
- Firewall rules: SSH (22) and gateway port (18789)
- Load balancer (`openclaw-lb`) with health check on `/healthz`
- SSL certificate for your domain
- IAM user `openclaw-bedrock` with a Bedrock inference policy
- IAM access key for that user

### Two-phase SSL certificate

Lightsail SSL requires DNS validation before the certificate can be attached to the load balancer. The workflow is:

1. Run `terraform apply` — this creates the cert and outputs validation records
2. Check `terraform output cert_validation_records` — add those CNAME records in your DNS provider
3. Wait 5–30 minutes for Let's Encrypt validation
4. Run `terraform apply` again — this attaches the cert and enables HTTPS

### Retrieve secrets after apply

```bash
# Static IP (add to GitHub Actions secret LIGHTSAIL_IP)
terraform output static_ip

# Bedrock IAM credentials (add to /opt/openclaw/.env on the instance)
terraform output bedrock_access_key_id
terraform output -raw bedrock_secret_access_key
```

> **State security**: Terraform state contains the IAM secret key. Use a secured remote backend (S3 + DynamoDB with encryption) rather than local state for any shared or long-lived deployment.

### Available Terraform variables

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `instance_name` | `openclaw-vaniam` | Lightsail instance name |
| `bundle_id` | `large_3_0` | Instance plan (4 vCPU / 8 GB / 160 GB / $40mo) |
| `blueprint_id` | `ubuntu_22_04` | OS image |
| `lb_name` | `openclaw-lb` | Load balancer name |
| `domain_name` | *(required)* | FQDN for SSL certificate |
| `gateway_port` | `18789` | Gateway listen port |
| `iam_user_name` | `openclaw-bedrock` | IAM user name |
| `iam_policy_name` | `openclaw-bedrock-policy` | IAM policy name |

---

## Phase 2 — Enable Bedrock Model Access

This step is manual — Terraform cannot do it.

In AWS Console → **Bedrock** → **Model access** (in `us-east-1`):

Enable at minimum:
- `anthropic.claude-3-5-sonnet-20241022-v2:0` — recommended default model
- `anthropic.claude-3-5-haiku-20241022-v1:0` — fast/cheap model for lightweight tasks

Model access requests for Anthropic models in `us-east-1` are typically approved instantly.

---

## Phase 3 — Slack App Setup

Socket Mode lets the gateway connect outbound to Slack. No public webhook URL is required — the gateway opens a persistent WebSocket to Slack's API.

### Create the app

1. [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**
2. Name: `OpenClaw`, Workspace: your workspace

### Enable Socket Mode

1. **Socket Mode** (left nav) → Enable
2. Generate an **App-Level Token** with scope `connections:write`
3. Save the token (starts with `xapp-`) as `SLACK_APP_TOKEN`

### Bot token scopes

**OAuth & Permissions** → **Bot Token Scopes** → add:

```
app_mentions:read   channels:history    channels:read
chat:write          files:read          files:write
groups:history      groups:read         im:history
im:read             im:write            mpim:history
mpim:read           mpim:write          reactions:read
reactions:write     users:read          users:read.email
```

### Event subscriptions

**Event Subscriptions** → **Enable Events** → subscribe to bot events:

```
app_mention   message.channels   message.groups
message.im    message.mpim
```

### Install and copy token

**OAuth & Permissions** → **Install to Workspace** → Authorize.

Copy the **Bot User OAuth Token** (starts with `xoxb-`) — save as `SLACK_BOT_TOKEN`.

---

## Phase 4 — Secrets on the Instance

SSH into the instance and create the secrets file. This is done once manually. CI/CD never touches this file.

```bash
ssh ubuntu@<STATIC_IP>

# Confirm Docker is ready (user-data may still be running on a fresh instance)
docker --version

# Create the secrets file
sudo mkdir -p /opt/openclaw
sudo tee /opt/openclaw/.env > /dev/null <<'EOF'
# Gateway auth — generate with: openssl rand -hex 32
OPENCLAW_GATEWAY_TOKEN=REPLACE_WITH_STRONG_RANDOM_TOKEN

TZ=UTC

# AWS Bedrock (from terraform output)
AWS_ACCESS_KEY_ID=REPLACE_WITH_IAM_KEY_ID
AWS_SECRET_ACCESS_KEY=REPLACE_WITH_IAM_SECRET
AWS_DEFAULT_REGION=us-east-1

# Slack
SLACK_BOT_TOKEN=xoxb-REPLACE
SLACK_APP_TOKEN=xapp-REPLACE
EOF

sudo chmod 600 /opt/openclaw/.env
sudo chown ubuntu:ubuntu /opt/openclaw/.env
```

Generate the gateway token: `openssl rand -hex 32`

### Create the production Docker Compose file

```bash
sudo tee /opt/openclaw/docker-compose.prod.yml > /dev/null <<'EOF'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE}
    env_file:
      - /opt/openclaw/.env
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_BIND: lan
    volumes:
      - openclaw-state:/home/node/.openclaw
      - openclaw-workspace:/home/node/.openclaw/workspace
    ports:
      - "18789:18789"
    init: true
    restart: unless-stopped
    command:
      - node
      - dist/index.js
      - gateway
      - --allow-unconfigured
      - --bind
      - lan
      - --port
      - "18789"
    healthcheck:
      test:
        - CMD
        - node
        - -e
        - "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

volumes:
  openclaw-state:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /opt/openclaw/state
  openclaw-workspace:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /opt/openclaw/workspace
EOF

sudo chown ubuntu:ubuntu /opt/openclaw/docker-compose.prod.yml
```

---

## Phase 5 — GitHub Actions CI/CD

### Generate a deploy SSH key

On your local machine:

```bash
ssh-keygen -t ed25519 -C "github-actions-openclaw" -f ~/.ssh/openclaw_deploy -N ""
```

Add the public key to the instance:

```bash
ssh ubuntu@<STATIC_IP> \
  "echo '$(cat ~/.ssh/openclaw_deploy.pub)' >> ~/.ssh/authorized_keys"
```

### Add GitHub Actions secrets

Repository → **Settings** → **Secrets and variables** → **Actions**:

| Secret | Value |
|---|---|
| `LIGHTSAIL_IP` | Static IP from `terraform output static_ip` |
| `LIGHTSAIL_SSH_KEY` | Contents of `~/.ssh/openclaw_deploy` (private key) |

`GITHUB_TOKEN` is built-in and used automatically for GHCR — no additional token needed for a public repository.

### Workflow: `.github/workflows/deploy-lightsail.yml`

The workflow triggers on every push to `vaniam-ai` (or manual dispatch) and does two things:

**Job 1 — Build & Push**
- Checks out `vaniam-ai`
- Builds the Docker image using the repo's multi-stage Dockerfile
- Pushes two tags to GHCR:
  - `:vaniam-ai` — mutable "latest for this branch" tag
  - `:vaniam-ai-<sha>` — immutable tag for rollbacks
- Uses GitHub Actions layer cache to keep repeat builds fast (5–8 min after the first 15–25 min cold build)

**Job 2 — Deploy**
- SSHs into the Lightsail instance
- Runs `docker pull` then `docker compose up -d --remove-orphans`
- Polls the container health status (up to 60 s) and exits non-zero if unhealthy
- Prunes old images tagged from this repository

### Trigger a deploy

```bash
git push origin vaniam-ai
```

Or manually: repository → **Actions** → **Deploy to Lightsail (vaniam-ai)** → **Run workflow**.

---

## Phase 6 — Post-Deploy Configuration

After the gateway is healthy, configure providers and channels from inside the container:

```bash
ssh ubuntu@<STATIC_IP>

docker compose -f /opt/openclaw/docker-compose.prod.yml \
  exec openclaw-gateway bash

# Inside the container:

# Set AWS Bedrock as the active provider
node dist/index.js config set providers.default bedrock
node dist/index.js config set providers.bedrock.region us-east-1

# Enable the Slack channel
node dist/index.js config set channels.slack.enabled true

# Verify
node dist/index.js channels status
```

Configuration is written to the named volume at `/home/node/.openclaw/openclaw.json` and persists across restarts and image updates.

---

## Phase 7 — Verification Checklist

### Gateway health

```bash
# From the instance
curl -sf http://localhost:18789/healthz   # → {"status":"ok",...}
curl -sf http://localhost:18789/readyz    # → {"status":"ready",...}

# From the internet (via load balancer)
curl -sf https://openclaw.yourdomain.com/healthz
```

### Load balancer

Lightsail Console → Load Balancers → `openclaw-lb` → **Target instances** — status must show `Healthy`.

If unhealthy: confirm port 18789 is open in the instance firewall and the container is running.

### Control UI

Open `https://openclaw.yourdomain.com` in a browser. The OpenClaw control panel should load. Enter `OPENCLAW_GATEWAY_TOKEN` when prompted.

### Slack bot

Invite `@OpenClaw` to a Slack channel and send a message. The bot should respond using a Bedrock Claude model.

### Bedrock direct test

```bash
# Inside the container
node dist/index.js agent --message "say hello" --provider bedrock
```

---

## Environment Variables Reference

### `/opt/openclaw/.env` (set manually on instance, never in CI)

| Variable | Required | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Strong random secret protecting the gateway API. Generate: `openssl rand -hex 32` |
| `TZ` | No | Container timezone. Default: `UTC` |
| `AWS_ACCESS_KEY_ID` | Yes | IAM access key from `terraform output bedrock_access_key_id` |
| `AWS_SECRET_ACCESS_KEY` | Yes | IAM secret from `terraform output -raw bedrock_secret_access_key` |
| `AWS_DEFAULT_REGION` | Yes | AWS region (`us-east-1` for widest Bedrock availability) |
| `SLACK_BOT_TOKEN` | Yes | Bot user OAuth token (`xoxb-...`) |
| `SLACK_APP_TOKEN` | Yes | Socket Mode app-level token (`xapp-...`) |

### Set by `docker-compose.prod.yml` (not in `.env`)

| Variable | Value | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_BIND` | `lan` | Bind to all interfaces (required for the port mapping to work) |
| `HOME` | `/home/node` | Required for state directory resolution |
| `NODE_ENV` | `production` | Set in the Docker image |

---

## Operations

### View logs

```bash
# Live
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml logs -f"

# Last 200 lines
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml logs --tail=200"
```

### Restart the gateway

```bash
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml restart openclaw-gateway"
```

### Reload config without restart

The gateway supports `SIGUSR1` for live config reload:

```bash
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml \
   exec openclaw-gateway kill -USR1 1"
```

### Manual deploy / emergency update

```bash
ssh ubuntu@<STATIC_IP>
docker pull ghcr.io/<owner>/<repo>:vaniam-ai
OPENCLAW_IMAGE=ghcr.io/<owner>/<repo>:vaniam-ai \
  docker compose -f /opt/openclaw/docker-compose.prod.yml up -d
```

### Rollback to a previous build

Every deploy creates an immutable `:vaniam-ai-<sha>` tag. Find available tags in the repository → **Packages** on GitHub, then:

```bash
ssh ubuntu@<STATIC_IP>
OPENCLAW_IMAGE=ghcr.io/<owner>/<repo>:vaniam-ai-<previous-sha> \
  docker compose -f /opt/openclaw/docker-compose.prod.yml up -d
```

### Backup state

```bash
# Create archive on instance
ssh ubuntu@<STATIC_IP> \
  "tar czf /tmp/openclaw-state-$(date +%Y%m%d).tar.gz /opt/openclaw/state"

# Copy to local machine
scp ubuntu@<STATIC_IP>:/tmp/openclaw-state-*.tar.gz ./backups/
```

Alternatively, create a Lightsail instance snapshot from the console (instance → **Snapshots**) before any destructive operation.

---

## Local Development

```bash
# Install dependencies
pnpm install

# Run type checks
pnpm tsgo

# Run lint + format checks
pnpm check

# Run tests
pnpm test

# Run the gateway in dev mode (auto-reloads on source changes)
pnpm gateway:watch

# Run the CLI directly (TypeScript, no build step)
pnpm openclaw gateway --bind loopback --port 18789
```

### Build the Docker image locally

```bash
docker build -t openclaw:local .
```

### Run locally with Docker Compose

```bash
docker compose up
```

The local gateway binds to `127.0.0.1:18789` by default.

---

## Open Items

These require your input before the deployment is fully complete:

1. **Domain name** — Update `openclaw.yourdomain.com` throughout with the actual domain, and pass it to `terraform apply -var="domain_name=..."`.
2. **GitHub repository owner** — Replace `<owner>/<repo>` in the workflow file and manual commands with the actual GitHub org/user and repo name.
3. **Bedrock models** — The recommended default is `anthropic.claude-3-5-sonnet-20241022-v2:0`. Confirm whether a different model should be default.
4. **AWS region** — Defaulting to `us-east-1`. If you prefer `us-west-2` or another region, update `aws_region` in Terraform and ensure Bedrock model access is enabled there.
5. **GitHub Actions environment** — The workflow references `environment: production`. Create this in the repo (Settings → Environments) if you want required reviewers or protection rules; remove the `environment:` line if not needed.
6. **Terraform remote state** — For a shared or long-lived deployment, configure an S3 + DynamoDB backend in `infra/main.tf` before running `terraform apply`. The IAM secret key is stored in state.
