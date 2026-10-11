# outputs.tf - Cloudflare SSL Modes lab
# Terraform builds the wrong-on-purpose stage and hands you the values the BY-HAND steps need.

output "origin_hostname" {
  description = "The proxied hostname for the lab (Terraform created its DNS record)."
  value       = var.origin_hostname
}

output "origin_ip" {
  description = "The origin's public IP (Elastic IP). The proxied DNS record points here."
  value       = aws_eip.origin.public_ip
}

output "instance_id" {
  description = "The origin EC2 instance id."
  value       = aws_instance.origin.id
}

output "ssm_command" {
  description = "Open an admin shell on the origin over SSM Session Manager - used to install the Origin CA pair. No SSH, no key pair, no open port. Needs the session-manager-plugin on your machine."
  value       = "aws ssm start-session --target ${aws_instance.origin.id}"
}

output "dns_record_id" {
  description = "Cloudflare DNS record id of the proxied record."
  value       = cloudflare_dns_record.app.id
}

output "check_redirect_loop" {
  description = "The redirect-loop demo from the video (Flexible mode + force-HTTPS origin)."
  value       = "curl -sSIL --max-redirs 2 --stderr - https://${var.origin_hostname}/ | grep -iE '^(http|location|curl)'"
}
