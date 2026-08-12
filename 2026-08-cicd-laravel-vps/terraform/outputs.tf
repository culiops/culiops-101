output "vps_public_ip" {
  description = "Public IP of the VPS. Set this as the GitHub secret VPS_HOST."
  value       = aws_instance.vps.public_ip
}

output "deploy_user" {
  description = "SSH user for deploys. Set as the GitHub secret DEPLOY_USER."
  value       = "deploy"
}

output "app_url" {
  description = "App URL once the first deploy lands."
  value       = "http://${aws_instance.vps.public_ip}"
}

output "ssh_hint" {
  description = "SSH in with the deploy private key."
  value       = "ssh -i deploy_key deploy@${aws_instance.vps.public_ip}"
}
