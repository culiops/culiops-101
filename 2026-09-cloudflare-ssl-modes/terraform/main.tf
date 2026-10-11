# main.tf - Cloudflare SSL Modes lab
#
# Terraform's job here is ONLY to build the "stage": an origin that is wrong on purpose, sitting
# behind a proxied Cloudflare DNS record.
#
#   origin  = nginx that FORCES HTTPS (port 80 -> 301 to https://$host$request_uri) and serves
#             443 with a SELF-SIGNED certificate
#   record  = proxied (orange cloud) DNS record for the origin hostname
#
# Everything that TEACHES - every SSL-mode change, creating the Cloudflare Origin CA certificate,
# installing it on the box - is done BY HAND in the demo. See the README.
# Teardown = `terraform destroy` for this stage, plus `cleanup.sh` for the zone-wide SSL setting
# that was changed by hand (Terraform never owned it, so destroy cannot undo it).

# --- Cloudflare zone guard ------------------------------------------------------
# The shared API token reaches PRODUCTION zones. Terraform refuses to plan unless the zone behind
# cloudflare_zone_id is the lab zone, and the hostname lives inside it.

data "cloudflare_zone" "lab" {
  zone_id = var.cloudflare_zone_id

  lifecycle {
    postcondition {
      condition     = self.name == var.lab_zone_name
      error_message = "REFUSING TO CONTINUE: cloudflare_zone_id points at zone '${self.name}', but lab_zone_name is '${var.lab_zone_name}'. Wrong zone id?"
    }
    postcondition {
      condition     = !contains(["culiops.dev", "culipulse.dev", "1cost.dev"], self.name)
      error_message = "REFUSING TO CONTINUE: '${self.name}' is a production zone. This lab changes zone-wide SSL settings."
    }
    postcondition {
      condition     = endswith(var.origin_hostname, ".${self.name}")
      error_message = "origin_hostname '${var.origin_hostname}' is not a subdomain of the lab zone '${self.name}'."
    }
  }
}

# --- Data sources ---------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

# Ubuntu 24.04 LTS (the dominant production LTS) from Canonical's official owner id.
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

# --- Locals ---------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# --- Network (self-contained - the sandbox account has no default VPC) ----------

resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name_prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security group -------------------------------------------------------------
#
# 80 AND 443 stay open to the world, on purpose. Flexible mode makes Cloudflare call port 80;
# Full / Full (strict) make it call 443; both must be reachable for the lesson to play out.
# This video does NOT teach locking the origin down to Cloudflare's IPs - that is the
# "origin still exposed" episode (youtube/2026-08-cloudflare-origin-exposed).

resource "aws_security_group" "origin" {
  name        = "${local.name_prefix}-origin"
  description = "Origin web server for the SSL modes lab - 80/443 open (no admin port; SSM only)"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "${local.name_prefix}-origin" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS (Cloudflare calls this in Full / Full strict)"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP (Cloudflare calls this in Flexible)"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All egress"
}

# --- IAM - SSM Session Manager access (no SSH, no key pair, no inbound port 22) --
#
# The origin is administered over AWS Systems Manager Session Manager. The box carries an
# instance profile with the SSM core permissions; in return the security group opens NO admin
# port. The "paste the Origin CA pair" shell is `aws ssm start-session`.
# (amazon-ssm-agent is pre-installed on the Ubuntu 24.04 AWS AMI.)

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "origin" {
  name               = "${local.name_prefix}-origin-ssm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_prefix}-origin-ssm" }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.origin.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "origin" {
  name = "${local.name_prefix}-origin-ssm"
  role = aws_iam_role.origin.name
}

# --- Origin instance + stable public IP -----------------------------------------

resource "aws_instance" "origin" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.origin.id]
  iam_instance_profile   = aws_iam_instance_profile.origin.name

  # nginx that forces HTTPS + a self-signed cert generated ON THE BOX at the exact paths the
  # nginx config (and the video's slide) points at. No secrets pass through user_data.
  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    origin_hostname = var.origin_hostname
  })

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  tags = { Name = "${local.name_prefix}-origin" }
}

resource "aws_eip" "origin" {
  domain = "vpc"
  tags   = { Name = "${local.name_prefix}-origin-eip" }
}

resource "aws_eip_association" "origin" {
  instance_id   = aws_instance.origin.id
  allocation_id = aws_eip.origin.id
}

# --- Cloudflare: the proxied DNS record (the orange cloud) -----------------------
#
# "Put the site behind Cloudflare" is plumbing the viewer has done 100 times - it carries no
# lesson - so it is part of the STAGE. The SSL-mode changes that follow are the lesson.
# ttl = 1 means "automatic" (required for proxied records).

resource "cloudflare_dns_record" "app" {
  zone_id = data.cloudflare_zone.lab.zone_id
  name    = var.origin_hostname
  type    = "A"
  content = aws_eip.origin.public_ip
  proxied = true
  ttl     = 1
  comment = "cloudflare-ssl-modes lab - safe to delete (managed by Terraform)"
}
