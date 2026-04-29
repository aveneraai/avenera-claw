variable "aws_region" {
  description = "AWS region to deploy into. us-east-1 has the widest Bedrock model availability."
  type        = string
  default     = "us-east-1"
}

variable "instance_name" {
  description = "Name for the Lightsail instance."
  type        = string
  default     = "openclaw-vaniam"
}

variable "bundle_id" {
  description = "Lightsail bundle (plan) ID. large_3_0 = 4 vCPU / 8 GB / 160 GB SSD / $40 mo."
  type        = string
  default     = "large_3_0"
}

variable "blueprint_id" {
  description = "Lightsail blueprint. ubuntu_22_04 matches the spec."
  type        = string
  default     = "ubuntu_22_04"
}

variable "lb_name" {
  description = "Name for the Lightsail load balancer."
  type        = string
  default     = "openclaw-lb"
}

variable "domain_name" {
  description = "Fully-qualified domain name for the SSL certificate (e.g. openclaw.yourdomain.com)."
  type        = string
}

variable "gateway_port" {
  description = "Port the gateway listens on inside the instance."
  type        = number
  default     = 18789
}

variable "iam_user_name" {
  description = "IAM user that holds Bedrock inference credentials."
  type        = string
  default     = "openclaw-bedrock"
}

variable "iam_policy_name" {
  description = "IAM policy name for Bedrock inference access."
  type        = string
  default     = "openclaw-bedrock-policy"
}

variable "attach_certificate" {
  description = "Set to true only after the SSL certificate has been validated (CNAME records added and AWS shows VALID). See lightsail_lb.tf for the two-phase apply instructions."
  type        = bool
  default     = false
}
