# outputs.tf — Cloudflare Origin Lockdown lab
# Terraform stands up the exposed origin and hands you the values the BY-HAND demo steps need.

output "origin_ip" {
  description = "The origin's real public IP (the Elastic IP). This is exactly what leaks via DNS history / crt.sh / Shodan and gets hit directly. Point your proxied Cloudflare A record at this."
  value       = aws_eip.origin.public_ip
}

output "origin_hostname" {
  description = "The hostname you will proxy in front of the origin (create the A record by hand)."
  value       = var.origin_hostname
}

output "security_group_id" {
  description = "The origin's security group. Layer 1 tightens THIS by hand (aws ec2 revoke/authorize-security-group-ingress)."
  value       = aws_security_group.origin.id
}

output "instance_id" {
  description = "The origin EC2 instance id."
  value       = aws_instance.origin.id
}

output "ssh_command" {
  description = "SSH into the origin for the Layer 2 (mTLS) step. Uses your key pair; replace the .pem path with your private key."
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.origin.public_ip}"
}

output "check_direct" {
  description = "THE 30-second exposure check — hit the origin IP directly, bypassing Cloudflare."
  value       = "curl -k --resolve ${var.origin_hostname}:443:${aws_eip.origin.public_ip} https://${var.origin_hostname}/ -o /dev/null -w '%%{http_code}\\n'"
}

output "check_via_cloudflare" {
  description = "The legit path — through Cloudflare. Should stay 200 in every state (once the A record exists)."
  value       = "curl -sS https://${var.origin_hostname}/ -o /dev/null -w '%%{http_code}\\n'"
}
