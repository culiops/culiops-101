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

# ─── The lab's core state switch ──────────────────────────────────────────────
variable "protection" {
  description = <<-EOT
    Which lock is applied to the origin. Drive the whole lab by re-applying with
    a new value and re-running the 30-second check after each:

      "none"          THE MISTAKE — SG open 0.0.0.0/0:443, plain nginx.
                      Direct hit on the origin IP returns 200. Origin is exposed.
      "ip_allowlist"  LAYER 1 — SG 443 restricted to Cloudflare's IP ranges only.
                      A direct hit from anywhere else times out (network-layer drop).
                      Weakness: the CF IP list changes; a stale allowlist blocks real traffic.
      "aop"           LAYER 2 — Authenticated Origin Pulls (mTLS). SG is reopened so the
                      origin is reachable, but nginx rejects any request that does NOT carry
                      Cloudflare's client certificate (HTTP 403). No IP list to keep fresh.
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "ip_allowlist", "aop"], var.protection)
    error_message = "protection must be one of: none, ip_allowlist, aop."
  }
}

# ─── Cloudflare ───────────────────────────────────────────────────────────────
variable "cloudflare_zone_id" {
  description = "Zone ID of your Cloudflare zone (Overview page, right sidebar). This lab MUST run on a throwaway/sandbox zone — it intentionally exposes an origin. Never a production zone."
  type        = string
}

variable "origin_hostname" {
  description = "Fully-qualified hostname to create for the origin (a subdomain of your zone), proxied through Cloudflare."
  type        = string
  default     = "cf-origin.culilab.dev"
}

# ─── Access / sizing ──────────────────────────────────────────────────────────
variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (port 22) into the origin box for inspection. Set to your own IP/32. Empty string disables SSH ingress entirely."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access (optional). Leave empty to skip — the lab works without SSH."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the origin. t3.micro is free-tier eligible and plenty."
  type        = string
  default     = "t3.micro"
}
