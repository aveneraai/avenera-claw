locals {
  user_data = <<-BASH
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
    echo '[Unit]'                                                                   > /etc/systemd/system/openclaw-gateway.service
    echo 'Description=OpenClaw Gateway'                                           >> /etc/systemd/system/openclaw-gateway.service
    echo 'After=network-online.target'                                            >> /etc/systemd/system/openclaw-gateway.service
    echo 'Wants=network-online.target'                                            >> /etc/systemd/system/openclaw-gateway.service
    echo ''                                                                        >> /etc/systemd/system/openclaw-gateway.service
    echo '[Service]'                                                               >> /etc/systemd/system/openclaw-gateway.service
    echo 'Type=simple'                                                             >> /etc/systemd/system/openclaw-gateway.service
    echo 'User=ubuntu'                                                             >> /etc/systemd/system/openclaw-gateway.service
    echo 'Group=ubuntu'                                                            >> /etc/systemd/system/openclaw-gateway.service
    echo 'WorkingDirectory=/opt/openclaw/app'                                     >> /etc/systemd/system/openclaw-gateway.service
    echo 'EnvironmentFile=-/opt/openclaw/.env'                                    >> /etc/systemd/system/openclaw-gateway.service
    echo 'Environment=HOME=/home/ubuntu'                                          >> /etc/systemd/system/openclaw-gateway.service
    echo 'Environment=NODE_ENV=production'                                        >> /etc/systemd/system/openclaw-gateway.service
    echo 'ExecStart=/usr/bin/node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789' >> /etc/systemd/system/openclaw-gateway.service
    echo 'Restart=on-failure'                                                     >> /etc/systemd/system/openclaw-gateway.service
    echo 'RestartSec=10'                                                          >> /etc/systemd/system/openclaw-gateway.service
    echo 'StandardOutput=journal'                                                 >> /etc/systemd/system/openclaw-gateway.service
    echo 'StandardError=journal'                                                  >> /etc/systemd/system/openclaw-gateway.service
    echo 'SyslogIdentifier=openclaw-gateway'                                      >> /etc/systemd/system/openclaw-gateway.service
    echo ''                                                                        >> /etc/systemd/system/openclaw-gateway.service
    echo '[Install]'                                                               >> /etc/systemd/system/openclaw-gateway.service
    echo 'WantedBy=multi-user.target'                                             >> /etc/systemd/system/openclaw-gateway.service

    systemctl daemon-reload
    systemctl enable openclaw-gateway

    # Allow ubuntu to manage the openclaw service without a password prompt
    echo 'ubuntu ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload, /bin/systemctl enable openclaw-gateway, /bin/systemctl start openclaw-gateway, /bin/systemctl stop openclaw-gateway, /bin/systemctl restart openclaw-gateway, /bin/systemctl status openclaw-gateway' > /etc/sudoers.d/openclaw-gateway
    chmod 440 /etc/sudoers.d/openclaw-gateway
  BASH
}

resource "aws_lightsail_instance" "openclaw" {
  name              = var.instance_name
  availability_zone = "${var.aws_region}a"
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  user_data         = local.user_data

  tags = {
    Project = "openclaw"
    Branch  = "vaniam-ai"
  }
}

# ── Static IP ────────────────────────────────────────────────────────────────

resource "aws_lightsail_static_ip" "openclaw" {
  name = "${var.instance_name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "openclaw" {
  static_ip_name = aws_lightsail_static_ip.openclaw.name
  instance_name  = aws_lightsail_instance.openclaw.name
}

# ── Firewall ──────────────────────────────────────────────────────────────────
# Opens SSH (22) and the gateway port (18789).
# Port 80 is managed by Lightsail automatically when a LB is attached.

resource "aws_lightsail_instance_public_ports" "openclaw" {
  instance_name = aws_lightsail_instance.openclaw.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidrs     = ["0.0.0.0/0"]
  }

  port_info {
    protocol  = "tcp"
    from_port = var.gateway_port
    to_port   = var.gateway_port
    cidrs     = ["0.0.0.0/0"]
  }
}
