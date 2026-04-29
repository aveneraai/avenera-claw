output "static_ip" {
  description = "Static IP attached to the Lightsail instance. Add this as LIGHTSAIL_IP in GitHub Actions secrets."
  value       = aws_lightsail_static_ip.openclaw.ip_address
}

output "lb_dns_name" {
  description = "Load balancer DNS name. Create a CNAME record: <domain_name> → <lb_dns_name>."
  value       = aws_lightsail_lb.openclaw.dns_name
}

output "cert_validation_records" {
  description = "CNAME records to add to your DNS provider to validate the SSL certificate."
  value       = aws_lightsail_lb_certificate.openclaw.domain_validation_records
}

output "bedrock_access_key_id" {
  description = "AWS_ACCESS_KEY_ID for the Bedrock IAM user. Store in /opt/openclaw/.env on the instance."
  value       = aws_iam_access_key.bedrock.id
}

output "bedrock_secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY for the Bedrock IAM user. Store in /opt/openclaw/.env on the instance."
  value       = aws_iam_access_key.bedrock.secret
  sensitive   = true
}

output "ssh_connect" {
  description = "SSH command to connect to the instance."
  value       = "ssh ubuntu@${aws_lightsail_static_ip.openclaw.ip_address}"
}
