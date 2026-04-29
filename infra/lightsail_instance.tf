locals {
  user_data = <<-BASH
    #!/bin/bash
    set -eu

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

    systemctl enable docker
    systemctl start docker
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
