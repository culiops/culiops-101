variable "aws_region" {
  description = "AWS region for the lab VPS."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "culiops-deploy-lab"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type. t3.small (2 GB) is the floor for the full Dockerized stack
    (MySQL 8.4 + Redis + nginx + 3 PHP containers): t3.micro's 1 GB OOMs. Real lesson
    for cheap 1 GB VPSes — add swap, use an external DB, or size up.
  EOT
  type        = string
  default     = "t3.small"
}

variable "deploy_public_key" {
  description = <<-EOT
    SSH PUBLIC key for the `deploy` user (the DEDICATED deploy key, not your
    personal one). The matching PRIVATE key goes into the GitHub repo secret
    DEPLOY_SSH_KEY. Generate: ssh-keygen -t ed25519 -f deploy_key -C deploy
  EOT
  type        = string
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH in. GitHub-hosted runners use many IPs, so 0.0.0.0/0 is the lab default; lock it down for anything real."
  type        = string
  default     = "0.0.0.0/0"
}

variable "db_password" {
  description = "MySQL password for the app user (lab only — not a real secret)."
  type        = string
  default     = "change-me-in-tfvars"
  sensitive   = true
}

variable "image_repo" {
  description = <<-EOT
    The GHCR image repo CI pushes to and the VPS pulls from, e.g.
    ghcr.io/<your-github>/deploy-laravel-vps (lowercase). deploy.sh runs
    <image_repo>:<commit-sha>. Make the package public, or `docker login ghcr.io`
    on the box for a private one.
  EOT
  type        = string
}
