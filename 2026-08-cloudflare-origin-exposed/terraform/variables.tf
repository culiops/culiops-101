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

# ─── SSH — REQUIRED for Layer 2 ───────────────────────────────────────────────
# Layer 2 (Authenticated Origin Pulls) is applied by SSHing into the box and adding an nginx
# mTLS snippet on camera. Both of these must be set, or you cannot reach the box to do it.
variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access. REQUIRED — the Layer 2 step SSHes into the origin to enable mTLS."
  type        = string

  validation {
    condition     = length(var.key_name) > 0
    error_message = "key_name is required: Layer 2 SSHes into the origin. Create/import an EC2 key pair first."
  }
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (port 22) into the origin. Set to YOUR public IP as /32. REQUIRED for the Layer 2 step."
  type        = string

  validation {
    condition     = can(cidrhost(var.ssh_ingress_cidr, 0))
    error_message = "ssh_ingress_cidr must be a valid CIDR, e.g. 203.0.113.10/32 (your public IP)."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the origin. t3.micro is free-tier eligible and plenty."
  type        = string
  default     = "t3.micro"
}
