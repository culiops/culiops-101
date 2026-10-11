variable "aws_region" {
  description = "AWS region for all lab resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Name prefix for all resources. Lowercase letters, numbers, hyphens only."
  type        = string
  default     = "cf-ssl-lab"

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

# --- Cloudflare zone (THROWAWAY ONLY) ------------------------------------------
variable "cloudflare_zone_id" {
  description = "Zone ID of your THROWAWAY Cloudflare zone (zone Overview page, right sidebar). Terraform creates one proxied DNS record in it. Set via TF_VAR_cloudflare_zone_id (see .env.example)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be a 32-character lowercase hex string."
  }
}

variable "lab_zone_name" {
  description = "Name of the lab zone. Terraform aborts (plan-time postcondition) unless the zone behind cloudflare_zone_id has exactly this name. Safety net: the shared API token can reach production zones."
  type        = string
  default     = "culilab.dev"

  validation {
    condition     = !contains(["culiops.dev", "culipulse.dev", "1cost.dev"], var.lab_zone_name)
    error_message = "lab_zone_name is a PRODUCTION zone. This lab flips zone-wide SSL settings - use a throwaway zone."
  }
}

variable "origin_hostname" {
  description = "Fully-qualified hostname for the origin: a subdomain of lab_zone_name. Terraform creates its proxied DNS record, and uses it as the nginx server_name and the self-signed cert CN/SAN."
  type        = string
  default     = "app.culilab.dev"
}

variable "instance_type" {
  description = "EC2 instance type for the origin. t3.micro is plenty for nginx."
  type        = string
  default     = "t3.micro"
}

# --- Admin access - SSM Session Manager, NOT SSH -------------------------------
# The Origin CA pair is installed by opening a shell on the box on camera. That shell comes
# from AWS Systems Manager Session Manager: no SSH, no key pair, NO inbound port 22.
# There is nothing to set here - the box gets an SSM instance profile (see main.tf).
