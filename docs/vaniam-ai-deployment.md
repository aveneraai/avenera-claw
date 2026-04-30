# vaniam-ai Deployment Guide

This guide covers deploying the OpenClaw gateway to AWS Lightsail on the `vaniam-ai` branch.

**Stack:** AWS Lightsail Instance (Ubuntu 22.04) · AWS Bedrock (Claude Sonnet 4.5) · Slack (Socket Mode) · GitHub Actions CI/CD · Terraform

---

## Architecture

```
Internet (HTTPS 443)
        │
        ▼
Lightsail Load Balancer  ── SSL termination (vaniam-ai.avenera.ai)
        │
        ▼  HTTP :18789
Lightsail Instance  (8 vCPU / 32 GB / 640 GB SSD · $160/mo)
  └── openclaw-gateway  (Node.js process, managed by systemd)
        state: /home/ubuntu/.openclaw

GitHub Actions (push to vaniam-ai)
  1. pnpm install + build + prune prod deps
  2. rsync dist/ node_modules/ … → /opt/openclaw/app/
  3. SSH → systemctl restart openclaw-gateway → /healthz check
```

---

## Infrastructure

| Resource          | Value                                                                     |
| ----------------- | ------------------------------------------------------------------------- |
| Domain            | `vaniam-ai.avenera.ai`                                                    |
| Static IP         | `98.94.121.111`                                                           |
| Load Balancer DNS | `904b314ec673554bc44c6bf456afbc5a-1426260798.us-east-1.elb.amazonaws.com` |
| Instance name     | `openclaw-vaniam`                                                         |
| AWS Region        | `us-east-1`                                                               |
| Gateway port      | `18789`                                                                   |
| IAM user          | `openclaw-bedrock`                                                        |

---

## DNS Records

| Type    | Name                                                     | Value                                                                     | Purpose                        |
| ------- | -------------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------ |
| `CNAME` | `vaniam-ai.avenera.ai`                                   | `904b314ec673554bc44c6bf456afbc5a-1426260798.us-east-1.elb.amazonaws.com` | Points domain to load balancer |
| `CNAME` | `_b80eb828c2dd19ad3c0d49a29bf8fdc6.vaniam-ai.avenera.ai` | `_5bff4912547e6864c8d5b081a7f8350e.jkddzztszm.acm-validations.aws`        | SSL certificate validation     |

After adding DNS records, wait 5–30 minutes for AWS to validate the certificate, then run:

```bash
cd infra && terraform apply -var="attach_certificate=true"
```

---

## SSH Access

```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111
```

The Lightsail default key is at `keys/LightsailDefaultKey-us-east-1.pem` (gitignored).

The GitHub Actions deploy key is at `keys/openclaw_deploy` (gitignored).

---

## Instance File Layout

| Path                     | Purpose                                         |
| ------------------------ | ----------------------------------------------- |
| `/opt/openclaw/.env`     | Secrets (gateway token, AWS keys, Slack tokens) |
| `/opt/openclaw/app/`     | Deployed application (dist, node_modules, etc.) |
| `/home/ubuntu/.openclaw` | Persistent gateway state and workspace          |

---

## Secrets

### `/opt/openclaw/.env` on the instance

| Variable                 | Description                                                 |
| ------------------------ | ----------------------------------------------------------- |
| `OPENCLAW_GATEWAY_TOKEN` | Strong random secret — generate with `openssl rand -hex 32` |
| `AWS_ACCESS_KEY_ID`      | From `terraform output bedrock_access_key_id`               |
| `AWS_SECRET_ACCESS_KEY`  | From `terraform output -raw bedrock_secret_access_key`      |
| `AWS_DEFAULT_REGION`     | `us-east-1`                                                 |
| `SLACK_BOT_TOKEN`        | Bot user OAuth token (`xoxb-...`)                           |
| `SLACK_APP_TOKEN`        | Socket Mode app-level token (`xapp-...`)                    |

To edit: `sudo nano /opt/openclaw/.env`

### GitHub Actions secrets

| Secret              | Value                              |
| ------------------- | ---------------------------------- |
| `LIGHTSAIL_IP`      | `98.94.121.111`                    |
| `LIGHTSAIL_SSH_KEY` | Contents of `keys/openclaw_deploy` |

---

## CI/CD

Workflow: `.github/workflows/deploy-lightsail.yml`

Triggers on every push to `vaniam-ai`. Single job with the `production` environment:

1. **Build** — installs deps, runs `pnpm build:docker` + UI builds, prunes to production deps
2. **rsync** — transfers `dist/`, `node_modules/`, `extensions/`, `skills/`, `docs/`, `qa/`, `package.json`, `openclaw.mjs` to `/opt/openclaw/app/` via rsync
3. **Restart** — runs `systemctl restart openclaw-gateway`, polls `/healthz`

**Trigger a deploy:**

```bash
git push origin vaniam-ai
```

**Manual trigger:** GitHub → Actions → _Deploy to Lightsail (vaniam-ai)_ → Run workflow

**Rollback to a previous commit:**

```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111
# Run the workflow manually from the desired commit SHA via GitHub UI
```

---

## Post-Deploy Configuration

The deploy workflow automatically sets the Bedrock model after each deploy. For manual configuration or first-time setup, run commands directly on the instance:

```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111
cd /opt/openclaw/app
```

```bash
# Set Bedrock as the default model (cross-region inference profile required)
node openclaw.mjs config set agents.defaults.model bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0

# Enable Slack (once tokens are configured in .env)
node openclaw.mjs config set channels.slack.enabled true

# Allow the Control UI from the public domain
node openclaw.mjs config set gateway.controlUi.allowedOrigins '["http://localhost:18789","http://127.0.0.1:18789","https://vaniam-ai.avenera.ai"]'

# Verify
node openclaw.mjs channels status
```

### Bedrock model

Active model: `us.anthropic.claude-sonnet-4-5-20250929-v1:0` (cross-region inference profile, `us-east-1`)

> **Note:** Use cross-region inference profile IDs (prefixed `us.` or `global.`) — on-demand model IDs without a profile prefix are not supported for these model versions.

### Test the agent

```bash
node openclaw.mjs agent --local --message "say hello" --agent main
```

---

## Verification

```bash
# Gateway health (from instance)
curl -sf http://localhost:18789/healthz

# Gateway health (via load balancer)
curl -sf https://vaniam-ai.avenera.ai/healthz

# Service status
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "sudo systemctl status openclaw-gateway --no-pager"
```

Load balancer health: Lightsail Console → Load Balancers → `openclaw-lb` → Target instances must show **Healthy**.

---

## Operations

**View logs:**

```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "journalctl -u openclaw-gateway -f"
```

**Restart gateway:**

```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "sudo systemctl restart openclaw-gateway"
```

**Backup state:**

```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "tar czf /tmp/openclaw-state-$(date +%Y%m%d).tar.gz /home/ubuntu/.openclaw"
scp -i keys/LightsailDefaultKey-us-east-1.pem \
  ubuntu@98.94.121.111:/tmp/openclaw-state-*.tar.gz ./backups/
```

---

## Terraform

```bash
cd infra

# Initial provision
terraform init
terraform apply

# After DNS + cert validation
terraform apply -var="attach_certificate=true"

# Useful outputs
terraform output static_ip
terraform output lb_dns_name
terraform output cert_validation_records
terraform output bedrock_access_key_id
terraform output -raw bedrock_secret_access_key
```
