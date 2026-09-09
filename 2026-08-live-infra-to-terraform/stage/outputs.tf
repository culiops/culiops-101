# outputs.tf — adopt-clickops-ec2 / stage
#
# scripts/01-setup-stage.sh reads these after `apply` (and after the
# `terraform state rm` that makes the instance + SG unmanaged) to fill in
# adopt/terraform.tfvars for the on-camera demo.

output "legacy_instance_id" {
  description = "Instance id of the unmanaged 'legacy' EC2 box — feed this into adopt/ as legacy_instance_id."
  value       = aws_instance.legacy.id
}

output "legacy_sg_id" {
  description = "Security group id of the unmanaged 'legacy' SG — feed this into adopt/ as legacy_sg_id."
  value       = aws_security_group.legacy.id
}

output "legacy_sg_name" {
  description = <<-EOT
    The real security group's `name` — feed this into adopt/ as
    legacy_sg_name. aws_security_group's `name` argument is force-new, so
    the adopt config MUST match it exactly or the import will show a SECOND
    forced replacement (the SG) on top of the AMI one this lab is about.
  EOT
  value       = aws_security_group.legacy.name
}

output "real_ami_id" {
  description = "The AMI id the legacy instance actually runs (Ubuntu 22.04, resolved at apply time). This is the ground truth the agent's 'latest' lookup fails to match."
  value       = aws_instance.legacy.ami
}

output "legacy_instance_name" {
  description = "The legacy instance's Name tag — feed into adopt/ as legacy_instance_name so the agent draft matches reality on everything but the ami."
  value       = "${local.name_prefix}-legacy"
}

output "subnet_id" {
  description = "Public subnet id — feed this into adopt/ as subnet_id."
  value       = aws_subnet.public.id
}

output "vpc_id" {
  description = "VPC id created for this lab."
  value       = aws_vpc.lab.id
}

output "agent_user_name" {
  description = "IAM user name standing in for the AI agent's read-only identity."
  value       = aws_iam_user.agent.name
}

output "name_prefix" {
  description = "The unique name prefix used for every resource in this lab run."
  value       = local.name_prefix
}

output "lab_summary" {
  description = "Everything the adopt/ root and scripts need, in one place."
  value = {
    project_name       = var.project_name
    environment        = var.environment
    region             = var.aws_region
    name_prefix        = local.name_prefix
    legacy_instance_id = aws_instance.legacy.id
    legacy_sg_id       = aws_security_group.legacy.id
    legacy_sg_name     = aws_security_group.legacy.name
    real_ami_id        = aws_instance.legacy.ami
    subnet_id          = aws_subnet.public.id
    vpc_id             = aws_vpc.lab.id
    agent_user_name    = aws_iam_user.agent.name
  }
}
