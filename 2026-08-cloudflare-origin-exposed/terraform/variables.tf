variable "aws_region" {
  description = "AWS region for all lab resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Name prefix for all resources. Lowercase letters, numbers, hyphens only."
  type        = string
  default     = "cf-origin-lab"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

# ─── Origin identity ──────────────────────────────────────────────────────────
# This is NOT a Terraform-managed Cloudflare resource — the DNS record is created BY HAND in
# the demo. Terraform only uses this value to name the origin's self-signed cert (CN) and the
# nginx server_name, and to pre-fill the copy-paste check commands in the outputs.
variable "origin_hostname" {
  description = "Fully-qualified hostname you will point at the origin (a subdomain of your throwaway Cloudflare zone). MUST be a sandbox zone — this lab intentionally exposes an origin. Never a production zone."
  type        = string
  default     = "cf-origin.culilab.dev"
}

# ─── Admin access — SSM Session Manager, NOT SSH ──────────────────────────────
# Layer 2 (Authenticated Origin Pulls) is applied by opening a shell on the box and adding an
# nginx mTLS snippet on camera. That shell comes from AWS Systems Manager Session Manager — no
# SSH, no key pair, and NO inbound port 22. There is nothing to set here: the box gets an SSM
# instance profile (see main.tf) and you reach it with `aws ssm start-session`.

variable "instance_type" {
  description = "EC2 instance type for the origin. t3.micro is free-tier eligible and plenty."
  type        = string
  default     = "t3.micro"
}
