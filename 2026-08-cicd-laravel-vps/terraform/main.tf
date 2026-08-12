# main.tf — a single public Ubuntu 24.04 LTS VPS, fully bootstrapped for atomic
# Laravel deploys (nginx + php8.4-fpm + mysql + redis + supervisor + deploy user).
#
# Resources:
#   - aws_security_group  : SSH (22) + HTTP (80) in
#   - aws_instance        : the VPS, with cloud-init user-data doing the full setup
#
# Cost: ~$0.01/hr (t3.micro) + a public IPv4 (~$0.005/hr). Run `terraform destroy`
# when done. See ../README.md.

data "aws_caller_identity" "current" {}

# Canonical Ubuntu 24.04 LTS (Noble Numbat) AMI — the dominant production LTS in
# 2026 and the one the ondrej/php PPA (php8.4) fully supports. 26.04 was too new:
# ondrej has no "resolute" repo yet, so its php8.4 packages aren't installable there.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ── Self-contained networking (no reliance on a default VPC — the sandbox has none) ──
resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name_prefix}-public" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = merge(local.tags, { Name = "${local.name_prefix}-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "vps" {
  name        = "${local.name_prefix}-sg"
  description = "Lab VPS: SSH + HTTP"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "SSH (deploy over SSH from GitHub runners)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_instance" "vps" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.vps.id]

  # Installs Docker, then drops the compose stack (docker-compose.yml, nginx conf,
  # deploy.sh) into /home/deploy/app — read from the lab root so there is ONE source
  # of truth: the same files the video shows and a BYO-VPS user runs directly.
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    deploy_public_key = var.deploy_public_key
    db_password       = var.db_password
    image_repo        = var.image_repo
    compose_yml       = file("${path.module}/../docker-compose.yml")
    nginx_conf        = file("${path.module}/../nginx/app.conf")
    deploy_sh         = file("${path.module}/../deploy.sh")
  })
  # Re-runs user-data if any of the above changes (recreates the instance).
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 12
    volume_type = "gp3"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-vps" })
}
