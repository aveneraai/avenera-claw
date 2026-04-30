# AWS Lightsail Deployment Spec — vaniam-ai Branch

## Architecture Decision

**Lightsail Instance (VM), not Lightsail Container Service.**

Lightsail Container Service has no persistent volume support. The gateway stores configuration, sessions, and workspace data in `~/.openclaw/` and requires that state to survive redeploys. Container Service would wipe it on every deploy. A Lightsail Instance (Ubuntu 22.04) gives us a 640 GB SSD that persists indefinitely.

**Runtime model**: GitHub Actions builds the TypeScript source on the runner, rsyncs the compiled output and production `node_modules` to the Lightsail instance, then SSHs in and restarts the systemd service. The application runs as a Node.js process managed by systemd — no Docker daemon or container overhead on the VM.

```
Internet (HTTPS 443)
        │
        ▼
Lightsail Load Balancer  ──── SSL termination (Let's Encrypt via your domain)
        │
        ▼  HTTP :18789
Lightsail Instance  (Ubuntu 22.04, 8 vCPU, 32 GB RAM, 640 GB SSD — $160/mo)
  ├── openclaw-gateway  (Node.js 24, managed by systemd)
  │     app:   /opt/openclaw/app/
  │     state: /home/ubuntu/.openclaw  (persists on SSD)
  └── Static IP (free when attached)

GitHub Actions (push to vaniam-ai)
  1. pnpm install + build + prune prod deps
  2. rsync dist/ node_modules/ … → /opt/openclaw/app/
  3. SSH → systemctl restart openclaw-gateway → /healthz check
```

## Cost Estimate

| Resource                | Plan                        | $/mo      |
| ----------------------- | --------------------------- | --------- |
| Lightsail Instance      | 8 vCPU / 32 GB / 640 GB SSD | $160      |
| Lightsail Load Balancer | 1 LB (SSL included)         | $18       |
| Static IP               | Attached to instance        | $0        |
| Data transfer           | 5 TB included               | $0        |
| **Total**               |                             | **~$178** |

Bedrock costs are pay-per-token on top of this.

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
3. Under "Launch script" (User data), paste the bootstrap script below. It installs Node.js 24 and registers the systemd service on first boot.

```bash
#!/bin/bash
set -eu

# System update
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Node.js 24 (official NodeSource repo)
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

# Create application directory structure
mkdir -p /opt/openclaw/app
chown -R ubuntu:ubuntu /opt/openclaw
chmod 700 /opt/openclaw

# systemd service for the OpenClaw gateway
cat > /etc/systemd/system/openclaw-gateway.service <<'SVCEOF'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/openclaw/app
EnvironmentFile=-/opt/openclaw/.env
Environment=HOME=/home/ubuntu
Environment=NODE_ENV=production
ExecStart=/usr/bin/node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw-gateway

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable openclaw-gateway

# Allow ubuntu to manage the openclaw service without a password prompt
echo 'ubuntu ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload, /bin/systemctl enable openclaw-gateway, /bin/systemctl start openclaw-gateway, /bin/systemctl stop openclaw-gateway, /bin/systemctl restart openclaw-gateway, /bin/systemctl status openclaw-gateway' \
  > /etc/sudoers.d/openclaw-gateway
chmod 440 /etc/sudoers.d/openclaw-gateway
```

> **Note**: The Terraform `lightsail_instance.tf` uses equivalent `echo` lines instead of a heredoc to avoid Terraform's `<<-` indentation-stripping interacting with the inner heredoc.

4. **Choose instance plan**: `$160/mo` (8 vCPU, 32 GB RAM, 640 GB SSD) — bundle ID `2xlarge_3_0`.
5. Give the instance a name, e.g., `openclaw-vaniam`.
6. Click **Create instance**.

> Boot takes 2–4 minutes. The user-data script runs in the background for another 2–3 minutes after first SSH is available.

### 1.2 Assign a Static IP

1. In Lightsail → **Networking** → **Create static IP**.
2. Attach it to `openclaw-vaniam`.
3. Note the IP — you'll need it for DNS and GitHub Actions secrets.

### 1.3 Configure Instance Firewall

In the instance's **Networking** tab → **IPv4 Firewall**, ensure these rules:

| Application | Protocol | Port  | Source                                               |
| ----------- | -------- | ----- | ---------------------------------------------------- |
| SSH         | TCP      | 22    | Your IP (or `0.0.0.0/0` if restricting via key only) |
| Custom      | TCP      | 18789 | `0.0.0.0/0` (token auth protects the gateway)        |

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
# Wait for user-data to finish if just created (check: node --version)
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

> The `.env` file is loaded by the systemd service via `EnvironmentFile=-/opt/openclaw/.env`. The `-` prefix means the service starts normally even if the file doesn't exist yet.

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

| Secret name         | Value                                              |
| ------------------- | -------------------------------------------------- |
| `LIGHTSAIL_IP`      | The static IP assigned in Phase 1.2                |
| `LIGHTSAIL_SSH_KEY` | Contents of `~/.ssh/openclaw_deploy` (private key) |

### 5.3 Workflow File

The workflow (`.github/workflows/deploy-lightsail.yml`) triggers on every push to `vaniam-ai` (or manual dispatch) and runs as a single job under the `production` environment:

```yaml
name: Deploy to Lightsail (vaniam-ai)

on:
  push:
    branches:
      - vaniam-ai
  workflow_dispatch:
    inputs:
      ref:
        description: Branch or commit to build and deploy
        default: vaniam-ai
        required: true

env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"

jobs:
  build-and-deploy:
    name: Build & Deploy to Lightsail
    runs-on: ubuntu-24.04
    environment: production
    permissions:
      contents: read

    steps:
      - name: Checkout
        uses: actions/checkout@v6
        with:
          ref: ${{ inputs.ref }}

      - name: Setup Node environment
        uses: ./.github/actions/setup-node-env

      - name: Bundle A2UI (with stub fallback)
        run: |
          pnpm canvas:a2ui:bundle || {
            mkdir -p src/canvas-host/a2ui
            printf '/* A2UI bundle unavailable */\n' > src/canvas-host/a2ui/a2ui.bundle.js
            printf 'stub\n' > src/canvas-host/a2ui/.bundle.hash
          }

      - name: Build app
        run: |
          pnpm build:docker
          pnpm ui:build
          pnpm qa:lab:build

      - name: Prune to production deps
        run: |
          printf 'packages:\n  - .\n  - ui\n' > pnpm-workspace.yaml
          CI=true NPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod
          node scripts/postinstall-bundled-plugins.mjs
          find dist -type f \
            \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) \
            -delete

      - name: Stage deploy files
        run: |
          mkdir -p _deploy
          cp -a dist node_modules extensions skills docs qa _deploy/
          cp package.json openclaw.mjs _deploy/

      - name: Set up SSH
        env:
          LIGHTSAIL_SSH_KEY: ${{ secrets.LIGHTSAIL_SSH_KEY }}
        run: |
          mkdir -p ~/.ssh
          echo "$LIGHTSAIL_SSH_KEY" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh-keyscan -H "${{ secrets.LIGHTSAIL_IP }}" >> ~/.ssh/known_hosts

      - name: rsync app to VM
        run: |
          rsync -az --delete \
            -e "ssh -i ~/.ssh/deploy_key" \
            _deploy/ \
            ubuntu@${{ secrets.LIGHTSAIL_IP }}:/opt/openclaw/app/

      - name: Restart and verify gateway
        uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.LIGHTSAIL_IP }}
          username: ubuntu
          key: ${{ secrets.LIGHTSAIL_SSH_KEY }}
          script: |
            set -euo pipefail
            sudo systemctl daemon-reload
            sudo systemctl enable openclaw-gateway
            sudo systemctl restart openclaw-gateway

            for i in $(seq 1 18); do
              if curl -sf http://127.0.0.1:18789/healthz > /dev/null 2>&1; then
                echo "Gateway healthy after $((i * 5))s"; break
              fi
              sleep 5
            done

            cd /opt/openclaw/app
            node openclaw.mjs config set agents.defaults.model \
              bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0 || true

            sudo systemctl status openclaw-gateway --no-pager
```

> **Build time**: The first build takes 15–25 minutes (TypeScript compilation, pnpm dep install, UI build). Subsequent builds reuse the pnpm store cache via `setup-node-env` and typically complete in 5–10 minutes.

### 5.4 First Deployment

Push to `vaniam-ai` or manually trigger the workflow:

```bash
git push origin vaniam-ai
```

Watch the Actions tab. On success, verify the gateway is running:

```bash
ssh ubuntu@<STATIC_IP> \
  "sudo systemctl status openclaw-gateway --no-pager && \
   curl -sf http://localhost:18789/healthz && echo ' ✓ healthy'"
```

---

## Phase 6 — Post-Deploy Configuration

After the gateway is healthy, configure providers and channels directly on the instance:

```bash
ssh ubuntu@<STATIC_IP>
cd /opt/openclaw/app

# Configure AWS Bedrock as the active provider
node openclaw.mjs config set providers.default bedrock
node openclaw.mjs config set providers.bedrock.region us-east-1

# Configure Slack channel
node openclaw.mjs config set channels.slack.enabled true

# Verify channel status
node openclaw.mjs channels status
```

> Configuration is written to `/home/ubuntu/.openclaw/openclaw.json` and persists across service restarts and redeploys.

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

If unhealthy: confirm port 18789 is open in the instance firewall (Phase 1.3) and the service is running.

### 7.3 Control UI

Open `https://openclaw.yourdomain.com` in a browser. The OpenClaw control UI should load. Enter the `OPENCLAW_GATEWAY_TOKEN` when prompted.

### 7.4 Slack Bot Test

Invite `@OpenClaw` to a Slack channel and send a message. The bot should respond using a Bedrock Claude model.

### 7.5 Bedrock Test

```bash
# On the instance
cd /opt/openclaw/app
node openclaw.mjs agent --message "say hello" --provider bedrock
```

---

## Phase 8 — Operations

### Update the Deployment

Push to `vaniam-ai` — GitHub Actions handles the rest automatically.

### Rollback to a Previous Commit

Trigger the workflow manually from GitHub UI and enter the specific commit SHA in the `ref` input. The rsync will overwrite `/opt/openclaw/app/` with the older build.

### View Logs

```bash
# Live
ssh ubuntu@<STATIC_IP> "journalctl -u openclaw-gateway -f"

# Last 200 lines
ssh ubuntu@<STATIC_IP> "journalctl -u openclaw-gateway -n 200"
```

### Restart the Gateway

```bash
ssh ubuntu@<STATIC_IP> "sudo systemctl restart openclaw-gateway"
```

### Backup State

The persistent state lives in `/home/ubuntu/.openclaw` on the instance SSD. Back it up before any destructive operation:

```bash
ssh ubuntu@<STATIC_IP> \
  "tar czf /tmp/openclaw-state-$(date +%Y%m%d).tar.gz /home/ubuntu/.openclaw"

scp ubuntu@<STATIC_IP>:/tmp/openclaw-state-*.tar.gz ./backups/
```

Alternatively, create a Lightsail snapshot of the instance from the console (Networking → Snapshots) before major updates.

### Reload Config Without Restart

The gateway supports `SIGUSR1` for config reload:

```bash
ssh ubuntu@<STATIC_IP> "sudo systemctl kill -s USR1 openclaw-gateway"
```

---

## Environment Variables Reference

All set in `/opt/openclaw/.env` on the instance. The systemd service loads them via `EnvironmentFile`.

| Variable                 | Required      | Description                                                                       |
| ------------------------ | ------------- | --------------------------------------------------------------------------------- |
| `OPENCLAW_GATEWAY_TOKEN` | Yes           | Strong random secret protecting the gateway API. Generate: `openssl rand -hex 32` |
| `TZ`                     | No            | Timezone. Default: `UTC`                                                          |
| `AWS_ACCESS_KEY_ID`      | Yes (Bedrock) | IAM access key for Bedrock inference                                              |
| `AWS_SECRET_ACCESS_KEY`  | Yes (Bedrock) | IAM secret key                                                                    |
| `AWS_DEFAULT_REGION`     | Yes (Bedrock) | AWS region. Use `us-east-1` for widest Bedrock model availability                 |
| `SLACK_BOT_TOKEN`        | Yes (Slack)   | Bot user OAuth token (`xoxb-...`)                                                 |
| `SLACK_APP_TOKEN`        | Yes (Slack)   | Socket Mode app-level token (`xapp-...`)                                          |

The following are set by the systemd unit directly (not in `.env`):

| Variable   | Value          | Description                             |
| ---------- | -------------- | --------------------------------------- |
| `HOME`     | `/home/ubuntu` | Required for state directory resolution |
| `NODE_ENV` | `production`   | Node.js production mode                 |

---

## Open Items

These items require your input before or during execution:

1. **Domain name** — Needed to complete the Load Balancer SSL certificate. Update `openclaw.yourdomain.com` throughout this spec with the actual domain.
2. **GitHub repository owner** — Replace `<owner>/<repo>` throughout with the actual GitHub organization/user and repository name (visible in the repo URL).
3. **Bedrock models** — Confirm which specific Bedrock model IDs should be the default. `anthropic.claude-3-5-sonnet-20241022-v2:0` is the recommended starting point.
4. **AWS region** — If you prefer a region other than `us-east-1` (e.g., `us-west-2`), update `AWS_DEFAULT_REGION` and ensure Bedrock model access is enabled in that region.
5. **GitHub Actions environment** — The workflow references `environment: production`. Create this environment in the repo (Settings → Environments) if you want required reviewers or deployment protection rules; delete the `environment:` line if not.
