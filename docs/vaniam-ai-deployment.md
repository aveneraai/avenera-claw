# vaniam-ai Deployment Guide

This guide covers deploying the OpenClaw gateway to AWS Lightsail on the `vaniam-ai` branch.

**Stack:** AWS Lightsail Instance (Ubuntu 22.04) · AWS Bedrock (Claude) · Slack (Socket Mode) · GitHub Actions CI/CD · Terraform

---

## Architecture

```
Internet (HTTPS 443)
        │
        ▼
Lightsail Load Balancer  ── SSL termination (vaniam-ai.avenera.ai)
        │
        ▼  HTTP :18789
Lightsail Instance  (4 vCPU / 8 GB / 160 GB SSD · $40/mo)
  └── Docker Engine
        └── openclaw-gateway container
              image : ghcr.io/aveneraai/avenera-claw:vaniam-ai
              port  : 18789
              volume: /opt/openclaw/state → /home/node/.openclaw

GitHub Actions (push to vaniam-ai)
  1. docker build → ghcr.io/aveneraai/avenera-claw:<sha> + :vaniam-ai
  2. SSH → docker compose pull && up -d → /healthz check
```

---

## Infrastructure

| Resource | Value |
|---|---|
| Domain | `vaniam-ai.avenera.ai` |
| Static IP | `98.94.121.111` |
| Load Balancer DNS | `904b314ec673554bc44c6bf456afbc5a-1426260798.us-east-1.elb.amazonaws.com` |
| Instance name | `openclaw-vaniam` |
| AWS Region | `us-east-1` |
| Gateway port | `18789` |
| IAM user | `openclaw-bedrock` |

---

## DNS Records

| Type | Name | Value | Purpose |
|---|---|---|---|
| `CNAME` | `vaniam-ai.avenera.ai` | `904b314ec673554bc44c6bf456afbc5a-1426260798.us-east-1.elb.amazonaws.com` | Points domain to load balancer |
| `CNAME` | `_b80eb828c2dd19ad3c0d49a29bf8fdc6.vaniam-ai.avenera.ai` | `_5bff4912547e6864c8d5b081a7f8350e.jkddzztszm.acm-validations.aws` | SSL certificate validation |

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

| Path | Purpose |
|---|---|
| `/opt/openclaw/.env` | Secrets (gateway token, AWS keys, Slack tokens) |
| `/opt/openclaw/docker-compose.prod.yml` | Production Compose file |
| `/opt/openclaw/state/` | Persistent gateway state (bind-mounted into container) |
| `/opt/openclaw/workspace/` | Agent workspace files |

---

## Secrets

### `/opt/openclaw/.env` on the instance

| Variable | Description |
|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | Strong random secret — generate with `openssl rand -hex 32` |
| `AWS_ACCESS_KEY_ID` | From `terraform output bedrock_access_key_id` |
| `AWS_SECRET_ACCESS_KEY` | From `terraform output -raw bedrock_secret_access_key` |
| `AWS_DEFAULT_REGION` | `us-east-1` |
| `SLACK_BOT_TOKEN` | Bot user OAuth token (`xoxb-...`) |
| `SLACK_APP_TOKEN` | Socket Mode app-level token (`xapp-...`) |

To edit: `sudo nano /opt/openclaw/.env`

### GitHub Actions secrets

| Secret | Value |
|---|---|
| `LIGHTSAIL_IP` | `98.94.121.111` |
| `LIGHTSAIL_SSH_KEY` | Contents of `keys/openclaw_deploy` |

---

## CI/CD

Workflow: `.github/workflows/deploy-lightsail.yml`

Triggers on every push to `vaniam-ai`. Two jobs:

1. **Build & Push** — builds the Docker image, pushes `:vaniam-ai` and `:vaniam-ai-<sha>` tags to GHCR
2. **Deploy** — SSHs into the instance, pulls the new image, runs `docker compose up -d`, polls `/healthz`

**Trigger a deploy:**
```bash
git push origin vaniam-ai
```

**Manual trigger:** GitHub → Actions → *Deploy to Lightsail (vaniam-ai)* → Run workflow

**Rollback to a previous build:**
```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111
OPENCLAW_IMAGE=ghcr.io/aveneraai/avenera-claw:vaniam-ai-<sha> \
  docker compose -f /opt/openclaw/docker-compose.prod.yml up -d
```

---

## Post-Deploy Configuration

After the first successful deploy, configure providers and channels inside the container:

```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111
docker compose -f /opt/openclaw/docker-compose.prod.yml exec openclaw-gateway bash

# Inside the container:
node dist/index.js config set providers.default bedrock
node dist/index.js config set providers.bedrock.region us-east-1
node dist/index.js config set channels.slack.enabled true
node dist/index.js channels status
```

---

## Verification

```bash
# Gateway health (from instance)
curl -sf http://localhost:18789/healthz

# Gateway health (via load balancer)
curl -sf https://vaniam-ai.avenera.ai/healthz

# Container status
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml ps"
```

Load balancer health: Lightsail Console → Load Balancers → `openclaw-lb` → Target instances must show **Healthy**.

---

## Operations

**View logs:**
```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml logs -f"
```

**Restart gateway:**
```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "docker compose -f /opt/openclaw/docker-compose.prod.yml restart openclaw-gateway"
```

**Backup state:**
```bash
ssh -i keys/LightsailDefaultKey-us-east-1.pem ubuntu@98.94.121.111 \
  "tar czf /tmp/openclaw-state-$(date +%Y%m%d).tar.gz /opt/openclaw/state"
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
