variable "aws_region" {
  description = "AWS region where all lab resources will be created."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = <<-EOT
    Unique name prefix for all resources created in this lab. Use lowercase
    letters, numbers, and hyphens only. culiops-sandbox is a SHARED account —
    keep the default prefix and let random_id.suffix guarantee uniqueness
    instead of hand-editing this into something collision-prone.
  EOT
  type        = string
  default     = "culiops-lab-adopt"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment. Used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "legacy_ami_id" {
  description = <<-EOT
    AMI the legacy click-ops box runs — pinned to a DELIBERATELY OLD Ubuntu
    22.04 (jammy) build so it is NOT the newest jammy. This guarantees the
    adopt/ demo's "latest" AMI lookup (jammy or noble) resolves to a newer id
    and forces a replacement in `terraform plan` — the whole point of the lab,
    and the safety margin the live-agent shoot needs. Region-specific
    (ap-southeast-1). If this id is ever deregistered, re-pick any jammy build a
    few months older than today:
      aws ec2 describe-images --owners 099720109477 --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        --query 'sort_by(Images,&CreationDate)[].[CreationDate,ImageId]' --output text
  EOT
  type        = string
  default     = "ami-0c687e8f5c4e54af5" # jammy 22.04 build 20251212 (ap-southeast-1)
}
