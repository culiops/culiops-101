# outputs.tf — adopt-clickops-ec2 / adopt

output "adopted_instance_id" {
  description = "Instance id now bound to Terraform state via the import block."
  value       = aws_instance.web.id
}

output "adopted_sg_id" {
  description = "Security group id now bound to Terraform state via the import block."
  value       = aws_security_group.web.id
}

output "lab_summary" {
  description = "Summary of the adopted resources and the config that now matches them."
  value = {
    project_name     = var.project_name
    environment      = var.environment
    region           = var.aws_region
    adopted_instance = aws_instance.web.id
    adopted_ami      = aws_instance.web.ami
    adopted_sg       = aws_security_group.web.id
  }
}
