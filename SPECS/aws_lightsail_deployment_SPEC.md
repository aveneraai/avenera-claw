# AWS Lightsail Deployment Spec — vaniam-ai Branch

## Architecture Decision

**Lightsail Instance (VM), not Lightsail Container Service.**

Lightsail Container Service has no persistent volume support. The gateway stores configuration, sessions, and workspace data in `~/.openclaw/` and requires that state to survive redeploys. Container Service would wipe it on every deploy. A Lightsail Instance (Ubuntu 22.04) gives us a 160 GB SSD that persists indefinitely.

**Runtime model**: GitHub Actions builds a Docker image from the `vaniam-ai` branch, pushes it to GitHub Container Registry (GHCR), then SSHs into the Lightsail instance and runs `docker compose pull && docker compose up -d`. The application itself runs inside Docker on the VM — reproducible builds without building on the instance, and easy rollbacks via image tags.

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
  │           volume: openclaw-state → /home/node/.openclaw  (persists on SSD)
  └── Static IP (free when attached)

GitHub Actions (push to vaniam-ai)
  1. docker build → ghcr.io/<owner>/<repo>:<sha> + :vaniam-ai
  2. SSH → docker compose pull && up -d → /healthz check
```

## Cost Estimate

| Resource | Plan | $/mo |
|---|---|---|
| Lightsail Instance | 4 vCPU / 8 GB / 160 GB SSD | $40 |
| Lightsail Load Balancer | 1 LB (SSL included) | $18 |
| Static IP | Attached to instance | $0 |
| Data transfer | 5 TB included | $0 |
| **Total** | | **~$58** |

GHCR is free for public repositories. No additional block storage is needed — 160 GB is ample for gateway state.

---

## Prerequisites

Before starting, collect or create:

- [ ] AWS account with billing enabled
- [ ] A domain name you control (required for Lightsail LB SSL via Let's Encrypt)
- [ ] AWS Bedrock model access enabled in the target region (`us-east-1` recommended — widest model availability). Enable via AWS Console → Bedrock → Model access.
- [ ] A Slack app with bot + Socket Mode tokens (details in Phase 5)
- [ ] GitHub account with write access to this repository

---

## Phase 1 — AWS Infrastructure

### 1.1 Create the Lightsail Instance

1. Open the [Lightsail console](https://lightsail.aws.amazon.com/ls/webapp/home/instances).
2. **Create instance** → Platform: **Linux/Unix** → Blueprint: **OS Only** → **Ubuntu 22.04 LTS**.
3. Under "Launch script" (User data), paste the bootstrap script below. It installs Docker on first boot so the instance is ready before any CI job connects.

```bash
#!/bin/bash
set -euo pipefail

# System update
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Docker (official repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Allow ubuntu user to run docker without sudo
usermod -aG docker ubuntu

# Create application directory structure
mkdir -p /opt/openclaw/{state,workspace}
chown -R ubuntu:ubuntu /opt/openclaw
chmod 700 /opt/openclaw

# Pull docker-compose config on first boot (CI will manage updates after this)
# Application starts after secrets are set in Phase 4
systemctl enable docker
systemctl start docker
```

4. **Choose instance plan**: `$40/mo` (4 vCPU, 8 GB RAM, 160 GB SSD).
5. Give the instance a name, e.g., `openclaw-vaniam`.
6. Click **Create instance**.

> Boot takes 2–4 minutes. The user-data script runs in the background for another 2–3 minutes after first SSH is available.

### 1.2 Assign a Static IP

1. In Lightsail → **Networking** → **Create static IP**.
2. Attach it to `openclaw-vaniam`.
3. Note the IP — you'll need it for DNS and GitHub Actions secrets.

### 1.3 Configure Instance Firewall

In the instance's **Networking** tab → **IPv4 Firewall**, ensure these rules:

| Application | Protocol | Port | Source |
|---|---|---|---|
| SSH | TCP | 22 | Your IP (or `0.0.0.0/0` if restricting via key only) |
| Custom | TCP | 18789 | `0.0.0.0/0` (token auth protects the gateway) |

> Port 80 is opened automatically by Lightsail when you attach to a load balancer. The LB forwards to :18789 after SSL termination.

### 1.4 Create a Load Balancer and SSL Certificate

1. Lightsail → **Networking** → **Create load balancer**.
2. Name: `openclaw-lb`
3. **Health check path**: `/healthz`
4. **Target instances**: attach `openclaw-vaniam`, port `18789`
5. After creation, open the LB → **Inbound traffic** tab → **Create certificate**.
   - Enter your domain (e.g., `openclaw.yourdomain.com`)
   - Add CNAME record in your DNS provider using the values shown
   - Wait for validation (5–30 min)
6. Once validated, go to **Protocols** → enable HTTPS on port 443 with the certificate.
7. Add a **HTTPS redirect**: HTTP → HTTPS.
8. In your DNS provider, point `openclaw.yourdomain.com` → **Load balancer DNS name** (shown on the LB overview page) as a CNAME record.

---

## Phase 2 — AWS Bedrock IAM Setup

The Lightsail instance cannot use EC2 instance profiles, so Bedrock access requires static IAM credentials.

### 2.1 Create an IAM Policy

In AWS Console → IAM → Policies → **Create policy** (JSON):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInference",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel"
      ],
      "Resource": "*"
    }
  ]
}
```

Name it `openclaw-bedrock-policy`.

### 2.2 Create an IAM User

1. IAM → Users → **Create user** → name: `openclaw-bedrock`
2. Attach policy: `openclaw-bedrock-policy`
3. Create **Access key** (use case: "Application running outside AWS")
4. Save `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` — you will need them in Phase 4.

### 2.3 Enable Model Access

In AWS Console → Bedrock → **Model access** (in your chosen region, e.g., `us-east-1`):

Enable at minimum:
- **Anthropic Claude 3.5 Sonnet** (`anthropic.claude-3-5-sonnet-20241022-v2:0`)
- **Anthropic Claude 3.5 Haiku** (`anthropic.claude-3-5-haiku-20241022-v1:0`)

Model access requests are usually approved instantly for Anthropic models in us-east-1.

---

## Phase 3 — Slack App Setup

### 3.1 Create the Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**
2. Name: `OpenClaw`, Workspace: your workspace

### 3.2 Configure Socket Mode

Socket Mode lets the gateway connect outbound to Slack (no public webhook URL required for events).

1. **Socket Mode** (left nav) → Enable Socket Mode
2. Generate an **App-Level Token** with scope `connections:write` → save this as `SLACK_APP_TOKEN` (starts with `xapp-`)

### 3.3 Configure Bot Token Scopes

Go to **OAuth & Permissions** → **Bot Token Scopes** → add:

```
app_mentions:read
channels:history
channels:read
chat:write
files:read
files:write
groups:history
groups:read
im:history
im:read
im:write
mpim:history
mpim:read
mpim:write
reactions:read
reactions:write
users:read
users:read.email
```

### 3.4 Enable Event Subscriptions

Go to **Event Subscriptions** → **Enable Events** → Subscribe to bot events:

```
app_mention
message.channels
message.groups
message.im
message.mpim
```

### 3.5 Install to Workspace

**OAuth & Permissions** → **Install to Workspace** → Authorize.

Copy the **Bot User OAuth Token** (starts with `xoxb-`) — save as `SLACK_BOT_TOKEN`.

---

## Phase 4 — Secrets and Environment Setup on Instance

SSH into the instance (`ssh ubuntu@<STATIC_IP>`) and create the secrets file. This is done once manually; the CI/CD pipeline never touches this file.

```bash
# Wait for user-data to finish if just created (check: docker --version)
sudo cat /var/log/cloud-init-output.log | tail -20

# Create the secrets file (not in git, not in CI)
sudo mkdir -p /opt/openclaw
sudo tee /opt/openclaw/.env > /dev/null <<'EOF'
# Gateway auth — generate with: openssl rand -hex 32
OPENCLAW_GATEWAY_TOKEN=REPLACE_WITH_STRONG_RANDOM_TOKEN

# Timezone
TZ=UTC

# AWS Bedrock
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

Generate the gateway token with: `openssl rand -hex 32`

### 4.1 Create the Production docker-compose Override

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

> Named volumes are backed by `/opt/openclaw/state` on the instance SSD. This data persists across container restarts and image updates. Back it up before destructive operations.

---

## Phase 5 — GitHub Actions CI/CD

### 5.1 Generate a Dedicated SSH Key for CI

On your local machine (not the Lightsail instance):

```bash
ssh-keygen -t ed25519 -C "github-actions-openclaw" -f ~/.ssh/openclaw_deploy -N ""
```

Add the **public key** to the instance:

```bash
ssh ubuntu@<STATIC_IP> \
  "echo '$(cat ~/.ssh/openclaw_deploy.pub)' >> ~/.ssh/authorized_keys"
```

### 5.2 Add GitHub Actions Secrets

In the repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret name | Value |
|---|---|
| `LIGHTSAIL_IP` | The static IP assigned in Phase 1.2 |
| `LIGHTSAIL_SSH_KEY` | Contents of `~/.ssh/openclaw_deploy` (private key) |

The `GITHUB_TOKEN` built-in secret is used automatically for GHCR — no additional token needed for a public repository.

### 5.3 Workflow File

Create `.github/workflows/deploy-lightsail.yml`:

```yaml
name: Deploy to Lightsail (vaniam-ai)

on:
  push:
    branches:
      - vaniam-ai
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-push:
    name: Build & Push Docker Image
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image: ${{ steps.meta.outputs.tags }}
      digest: ${{ steps.build.outputs.digest }}

    steps:
      - name: Checkout vaniam-ai
        uses: actions/checkout@v4
        with:
          ref: vaniam-ai

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract image metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=vaniam-ai
            type=sha,prefix=vaniam-ai-,format=short

      - name: Build and push image
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          # Layer cache keyed to the branch
          cache-from: type=gha,scope=vaniam-ai
          cache-to: type=gha,scope=vaniam-ai,mode=max
          # Build args (add OPENCLAW_EXTENSIONS here if needed)
          build-args: |
            OPENCLAW_VARIANT=default

  deploy:
    name: Deploy to Lightsail
    needs: build-and-push
    runs-on: ubuntu-latest
    environment: production

    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.LIGHTSAIL_IP }}
          username: ubuntu
          key: ${{ secrets.LIGHTSAIL_SSH_KEY }}
          script: |
            set -euo pipefail

            REGISTRY="ghcr.io"
            IMAGE="${REGISTRY}/${{ github.repository }}:vaniam-ai"

            echo "==> Pulling image: $IMAGE"
            # Public GHCR image — no login required for pull
            docker pull "$IMAGE"

            echo "==> Updating deployment"
            OPENCLAW_IMAGE="$IMAGE" \
              docker compose \
                -f /opt/openclaw/docker-compose.prod.yml \
                up -d --remove-orphans

            echo "==> Waiting for gateway to become healthy"
            for i in $(seq 1 12); do
              STATUS=$(docker compose \
                -f /opt/openclaw/docker-compose.prod.yml \
                ps --format json 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('Health','unknown'))" 2>/dev/null || echo "unknown")
              if [ "$STATUS" = "healthy" ]; then
                echo "Gateway healthy after $((i * 5))s"
                break
              fi
              echo "  Waiting... ($STATUS)"
              sleep 5
            done

            echo "==> Pruning old images"
            docker image prune -f --filter "label=org.opencontainers.image.source=https://github.com/${{ github.repository }}" || true

            echo "==> Deploy complete"
            docker compose -f /opt/openclaw/docker-compose.prod.yml ps
```

> **Build time**: The first build takes 15–25 minutes (compiles TypeScript, installs pnpm deps, builds UI). GitHub Actions layer cache (`cache-from`/`cache-to`) reduces subsequent builds to 5–8 minutes by reusing unchanged layers.

### 5.4 First Deployment

Push to `vaniam-ai` or manually trigger the workflow:

```bash
git push origin vaniam-ai
```

Watch the Actions tab. On success, verify the gateway is running on the instance:

```bash
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml ps && \
   curl -sf http://localhost:18789/healthz && echo ' ✓ healthy'"
```

---

## Phase 6 — Post-Deploy Configuration

After the gateway is healthy, configure the providers and channel via the CLI inside the container:

```bash
ssh ubuntu@<STATIC_IP>

# Open a shell in the running container
docker compose -f /opt/openclaw/docker-compose.prod.yml \
  exec openclaw-gateway bash

# Inside the container:
# Configure AWS Bedrock as the active provider
node dist/index.js config set providers.default bedrock

# Set the AWS region (if not already in env)
node dist/index.js config set providers.bedrock.region us-east-1

# Configure Slack channel
node dist/index.js config set channels.slack.enabled true

# Verify channel status
node dist/index.js channels status
```

> Configuration is written to the named volume (`/home/node/.openclaw/openclaw.json`) and persists across container restarts and image updates.

---

## Phase 7 — Verification Checklist

### 7.1 Gateway Health

```bash
# From the instance
curl -sf http://localhost:18789/healthz   # → {"status":"ok",...}
curl -sf http://localhost:18789/readyz    # → {"status":"ready",...}

# From the internet (via load balancer)
curl -sf https://openclaw.yourdomain.com/healthz
```

### 7.2 Load Balancer Health Check

Lightsail Console → Load Balancers → `openclaw-lb` → **Target instances** — status should show `Healthy`.

If unhealthy: confirm port 18789 is open in the instance firewall (Phase 1.3) and the container is running.

### 7.3 Control UI

Open `https://openclaw.yourdomain.com` in a browser. The OpenClaw control UI should load. Enter the `OPENCLAW_GATEWAY_TOKEN` when prompted.

### 7.4 Slack Bot Test

Invite `@OpenClaw` to a Slack channel and send a message. The bot should respond using a Bedrock Claude model.

### 7.5 Bedrock Test

```bash
# Inside the container
node dist/index.js agent --message "say hello" --provider bedrock
```

---

## Phase 8 — Operations

### Update the Deployment

Push to `vaniam-ai` — GitHub Actions handles the rest automatically.

For an emergency manual update:

```bash
ssh ubuntu@<STATIC_IP>
docker pull ghcr.io/<owner>/<repo>:vaniam-ai
OPENCLAW_IMAGE=ghcr.io/<owner>/<repo>:vaniam-ai \
  docker compose -f /opt/openclaw/docker-compose.prod.yml up -d
```

### Rollback to a Previous Build

Each deploy tags the image with both `:vaniam-ai` (latest) and `:vaniam-ai-<sha>` (immutable). To roll back:

```bash
ssh ubuntu@<STATIC_IP>
OPENCLAW_IMAGE=ghcr.io/<owner>/<repo>:vaniam-ai-<previous-sha> \
  docker compose -f /opt/openclaw/docker-compose.prod.yml up -d
```

Find available tags in the repository → **Packages** section on GitHub.

### View Logs

```bash
# Live logs
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml logs -f"

# Last 200 lines
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml logs --tail=200"
```

### Restart the Gateway

```bash
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml restart openclaw-gateway"
```

### Backup State

The persistent state lives in `/opt/openclaw/state` on the instance SSD. Back it up before any destructive operation:

```bash
ssh ubuntu@<STATIC_IP> \
  "tar czf /tmp/openclaw-state-$(date +%Y%m%d).tar.gz /opt/openclaw/state"

scp ubuntu@<STATIC_IP>:/tmp/openclaw-state-*.tar.gz ./backups/
```

Alternatively, create a Lightsail snapshot of the instance from the console (Networking → Snapshots) before major updates.

### Reload Config Without Restart

The gateway supports `SIGUSR1` for config reload:

```bash
ssh ubuntu@<STATIC_IP> \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml \
   exec openclaw-gateway kill -USR1 1"
```

---

## Environment Variables Reference

All set in `/opt/openclaw/.env` on the instance. Docker compose passes them into the container at startup.

| Variable | Required | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Strong random secret protecting the gateway API. Generate: `openssl rand -hex 32` |
| `TZ` | No | Container timezone. Default: `UTC` |
| `AWS_ACCESS_KEY_ID` | Yes (Bedrock) | IAM access key for Bedrock inference |
| `AWS_SECRET_ACCESS_KEY` | Yes (Bedrock) | IAM secret key |
| `AWS_DEFAULT_REGION` | Yes (Bedrock) | AWS region. Use `us-east-1` for widest Bedrock model availability |
| `SLACK_BOT_TOKEN` | Yes (Slack) | Bot user OAuth token (`xoxb-...`) |
| `SLACK_APP_TOKEN` | Yes (Slack) | Socket Mode app-level token (`xapp-...`) |

The following are set by the `docker-compose.prod.yml` directly (not in `.env`):

| Variable | Value | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_BIND` | `lan` | Bind to all interfaces (required for port mapping) |
| `HOME` | `/home/node` | Required for state directory resolution |
| `NODE_ENV` | `production` | Set in the Docker image |

---

## Open Items

These items require your input before or during execution:

1. **Domain name** — Needed to complete the Load Balancer SSL certificate. Update `openclaw.yourdomain.com` throughout this spec with the actual domain.
2. **GitHub repository owner** — Replace `<owner>/<repo>` throughout with the actual GitHub organization/user and repository name (visible in the repo URL).
3. **Bedrock models** — Confirm which specific Bedrock model IDs should be the default. `anthropic.claude-3-5-sonnet-20241022-v2:0` is the recommended starting point.
4. **AWS region** — If you prefer a region other than `us-east-1` (e.g., `us-west-2`), update `AWS_DEFAULT_REGION` and ensure Bedrock model access is enabled in that region.
5. **GitHub Actions environment** — The workflow references `environment: production`. Create this environment in the repo (Settings → Environments) if you want required reviewers or deployment protection rules; delete the `environment:` line if not.
