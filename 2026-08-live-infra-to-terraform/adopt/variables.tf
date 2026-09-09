variable "aws_region" {
  description = "AWS region where the adopted resources live."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Must match stage's project_name — used only for the default_tags comparison, not for naming (imported resources keep their real names)."
  type        = string
  default     = "culiops-lab-adopt"
}

variable "environment" {
  description = "Must match stage's environment — used only for the default_tags comparison."
  type        = string
  default     = "dev"
}

# ─── Adoption targets (fill from `cd ../stage && terraform output`) ──────────
# No defaults on purpose: these identify real, already-existing resources
# and should never be silently defaulted.

variable "subnet_id" {
  description = "Subnet id the legacy instance lives in (stage output: subnet_id)."
  type        = string
}

variable "legacy_instance_id" {
  description = "Instance id of the unmanaged legacy EC2 box to import (stage output: legacy_instance_id)."
  type        = string
}

variable "legacy_sg_id" {
  description = "Security group id of the unmanaged legacy SG to import (stage output: legacy_sg_id)."
  type        = string
}

variable "legacy_sg_name" {
  description = <<-EOT
    The real security group's `name` (stage output: legacy_sg_name).
    aws_security_group's `name` is force-new — this MUST match exactly or
    the import shows a second, unrelated forced replacement on the SG,
    muddying the one force-new diff (the AMI) this lab is about. Not in the
    original 4-variable list this lab was scoped from; added because the SG
    cannot import cleanly without it — see README "Design notes".
  EOT
  type        = string
}

variable "real_ami_id" {
  description = "The AMI id the legacy instance actually runs (stage output: real_ami_id). This is THE fix — pin this instead of trusting a 'latest' data source lookup."
  type        = string
}

variable "legacy_instance_name" {
  description = <<-EOT
    The real instance's Name tag (stage output: legacy_instance_name).
    The agent read this off the running box along with every other
    attribute — the ONLY thing it got wrong is the ami (a 'latest' lookup
    instead of the pinned real id). Matching Name here keeps the plan's one
    and only diff the ami force-replacement, nothing else.
  EOT
  type        = string
}
