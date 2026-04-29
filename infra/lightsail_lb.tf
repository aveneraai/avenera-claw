resource "aws_lightsail_lb" "openclaw" {
  name              = var.lb_name
  instance_port     = var.gateway_port
  health_check_path = "/healthz"

  tags = {
    Project = "openclaw"
    Branch  = "vaniam-ai"
  }
}

resource "aws_lightsail_lb_attachment" "openclaw" {
  lb_name       = aws_lightsail_lb.openclaw.name
  instance_name = aws_lightsail_instance.openclaw.name
}

# ── SSL Certificate ───────────────────────────────────────────────────────────
# Two-phase apply required:
#
#   Phase A (attach_certificate = false, the default):
#     terraform apply
#     → Check `terraform output cert_validation_records`
#     → Add those CNAME records in your DNS provider
#     → Wait 5–30 min for AWS to validate the certificate
#
#   Phase B (after validation is shown as VALID in the Lightsail console):
#     terraform apply -var="attach_certificate=true"
#     → Attaches the cert and enables the HTTPS redirect

resource "aws_lightsail_lb_certificate" "openclaw" {
  name        = "${var.lb_name}-cert"
  lb_name     = aws_lightsail_lb.openclaw.name
  domain_name = var.domain_name
}

resource "aws_lightsail_lb_certificate_attachment" "openclaw" {
  count = var.attach_certificate ? 1 : 0

  lb_name          = aws_lightsail_lb.openclaw.name
  certificate_name = aws_lightsail_lb_certificate.openclaw.name
}

# ── HTTPS Redirect ────────────────────────────────────────────────────────────

resource "aws_lightsail_lb_https_redirection_policy" "openclaw" {
  count = var.attach_certificate ? 1 : 0

  lb_name = aws_lightsail_lb.openclaw.name
  enabled = true

  depends_on = [aws_lightsail_lb_certificate_attachment.openclaw]
}
