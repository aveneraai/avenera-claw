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
# After apply, Terraform outputs the CNAME validation records that must be
# added to your DNS provider before `aws_lightsail_lb_certificate_attachment`
# can succeed. Run `terraform apply` once to create the cert, add the DNS
# records, wait for validation (5–30 min), then `terraform apply` again to
# attach the certificate and enable HTTPS.

resource "aws_lightsail_lb_certificate" "openclaw" {
  name        = "${var.lb_name}-cert"
  lb_name     = aws_lightsail_lb.openclaw.name
  domain_name = var.domain_name
}

resource "aws_lightsail_lb_certificate_attachment" "openclaw" {
  lb_name          = aws_lightsail_lb.openclaw.name
  certificate_name = aws_lightsail_lb_certificate.openclaw.name

  # Prevents Terraform from trying to attach before DNS validation completes.
  # If attachment fails, add the DNS CNAME records from the `cert_validation_records`
  # output, wait for validation, then re-run `terraform apply`.
  depends_on = [aws_lightsail_lb_certificate.openclaw]
}

# ── HTTPS Redirect ────────────────────────────────────────────────────────────

resource "aws_lightsail_lb_https_redirection_policy" "openclaw" {
  lb_name = aws_lightsail_lb.openclaw.name
  enabled = true

  depends_on = [aws_lightsail_lb_certificate_attachment.openclaw]
}
