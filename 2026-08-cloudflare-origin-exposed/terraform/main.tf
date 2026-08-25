# main.tf — Cloudflare Origin Lockdown lab
#
# Terraform's job here is ONLY to stand up the "stage": a deliberately-exposed origin on AWS
# (VPC + public EC2 running plain nginx, open to the whole internet). That is the mistake the
# video opens with.
#
# Everything after that — putting Cloudflare in front, and the two locks (Layer 1 IP allowlist,
# Layer 2 Authenticated Origin Pulls) — is performed BY HAND in the demo, because watching each
# lock click into place is the lesson. See the README. Teardown = `terraform destroy` for this
# AWS stage, plus `cleanup.sh` for the by-hand Cloudflare zone artifacts.

# ─── Data sources ─────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

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

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ─── Network (self-contained — the sandbox account has no default VPC) ─────────

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

# ─── Security group — the STAGE opens it to the world (the mistake) ────────────
#
# Terraform ships the origin already wide open on 80/443 (0.0.0.0/0) — that is the exposed
# starting point, not a lesson. Layer 1 in the demo is a BY-HAND security-group change
# (`aws ec2 revoke/authorize-security-group-ingress`) that swaps this to Cloudflare's ranges,
# so the viewer watches the network lock happen. `terraform destroy` deletes this SG and every
# rule on it — hand-added or not — so the manual edits need no separate cleanup.

resource "aws_security_group" "origin" {
  name        = "${local.name_prefix}-origin"
  description = "Origin web server - starts open to the world; Layer 1 tightens it by hand"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "${local.name_prefix}-origin" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS open to the world (the mistake; Layer 1 replaces this by hand)"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP open to the world"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All egress"
}

# ─── IAM — SSM Session Manager access (no SSH, no key pair, no inbound port 22) ─
#
# The origin is administered over AWS Systems Manager Session Manager, not SSH. The box carries
# an instance profile with the SSM core permissions; in return the security group opens NO
# inbound admin port at all — exactly the posture this video argues for. The Layer 2 shell is
# `aws ssm start-session`, which needs no open port and no key. (Requires the AWS-managed
# amazon-ssm-agent, pre-installed on the Ubuntu 24.04 AWS AMI.)

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

# ─── Origin instance + stable public IP ───────────────────────────────────────

resource "aws_instance" "origin" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.origin.id]
  iam_instance_profile   = aws_iam_instance_profile.origin.name

  # Plain nginx, always. The 443 server block includes an (initially empty) mTLS snippet
  # directory, so Layer 2 is just "drop one file + reload" over an SSM shell — no in-place
  # editing of the main config on camera. See templates/cloud-init.sh.tftpl.
  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    origin_hostname = var.origin_hostname
  })

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
