# main.tf — adopt-clickops-ec2 / stage
#
# This root plays the part of "an environment that already exists" — the
# off-camera precondition for the video. It creates:
#   - A minimal VPC + one public subnet + IGW + route table
#     (culiops-sandbox has NO default VPC — see project-sandbox-account-is-shared)
#   - The "legacy" click-ops EC2 instance + its Security Group
#   - A scoped, read-only IAM policy + dedicated user standing in for the
#     AI agent's discovery credentials
#
# `scripts/01-setup-stage.sh` applies this root, THEN runs
# `terraform state rm` on the instance + security group so they become
# genuinely unmanaged — an honest stand-in for a resource someone clicked
# into existence in the console. From that point on, this root only "owns"
# the network + IAM plumbing; the instance and SG live on in AWS with nobody
# tracking them, exactly like the real thing this lab is about.
#
# Cost estimate: ~$0.03–0.05 for the lab's duration (t3.small < 1 hr).
# Run `../cleanup.sh` from the lab root when done.

# ─── Data Sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# The AMI the "legacy" box actually runs. Pinned to a DELIBERATELY OLD Ubuntu
# 22.04 build (var.legacy_ami_id), NOT `most_recent`, so the box is genuine aged
# click-ops infra. This is load-bearing for the live-agent shoot: whatever
# release the agent's draft looks up as "latest" (jammy OR noble), it resolves
# to a NEWER id than this box, so `terraform plan` always shows the ami
# force-replacement. A `most_recent` lookup here would tie the box to the newest
# jammy, and a live agent that also picked jammy-latest would match it → no
# forced replacement, no demo. The pinned id is frozen into the real_ami_id
# output (= the ground truth the adopt/ demo has to converge on).

# ─── Local Values ─────────────────────────────────────────────────────────────

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "${var.project_name}-${var.environment}-${random_id.suffix.hex}"
}

# ─── Networking ────────────────────────────────────────────────────────────────
# culiops-sandbox has no default VPC (deleted for hardening) — this lab must
# bring its own, minimal on purpose: one public subnet is all a single demo
# instance needs.

resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public"
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── "Legacy" click-ops resources ─────────────────────────────────────────────
# These two resources are the whole point of the lab. Right after `apply`,
# scripts/01-setup-stage.sh removes them from this root's state — from then
# on they are real, running, billable AWS resources that Terraform does not
# track. That is the honest stand-in for click-ops infra.

resource "aws_security_group" "legacy" {
  name        = "${local.name_prefix}-legacy-sg"
  description = "Security group for the legacy click-ops EC2 instance"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "public web listener - demo origin"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "unrestricted egress - demo box, no outbound-sensitive workload"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-legacy-sg"
  }
}

resource "aws_instance" "legacy" {
  ami                    = var.legacy_ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.legacy.id]

  # No key_pair, no SSH ingress — admin access is out of scope for this lab
  # (CuliOps convention: SSM Session Manager, not SSH; this box only needs
  # to exist as an adoption target, not be logged into).

  tags = {
    Name = "${local.name_prefix}-legacy"
  }
}

# ─── Agent read-only credentials ──────────────────────────────────────────────
# Models "an AI agent with read-only creds discovers it" from the script.
# Deliberately scoped: Describe*/Get*/GetCallerIdentity only, resource "*"
# because most ec2:Describe* actions do not support resource-level IAM
# conditions (an AWS API limitation, not a choice we're making here) — see
# ../agent/readonly-policy.json for the standalone doc and its caveats.

data "aws_iam_policy_document" "agent_readonly" {
  statement {
    sid    = "Ec2ReadOnlyDiscovery"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:Get*",
      "sts:GetCallerIdentity",
    ]
    # ec2:Describe*/Get* do not support resource-level restriction for most
    # actions — this is an AWS API constraint, not a deliberate broadening.
    resources = ["*"]
  }

  statement {
    sid    = "ExcludeSensitiveReads"
    effect = "Deny"
    actions = [
      # ec2:GetPasswordData returns the (encrypted) Windows admin password;
      # ec2:GetConsoleOutput can surface boot-time secrets baked into
      # user_data. "Read-only" is not a data boundary on its own — see
      # feedback-readonly-is-not-a-data-boundary — so these are explicitly
      # excluded even though they match the Allow statement above.
      "ec2:GetPasswordData",
      "ec2:GetConsoleOutput",
      "ec2:GetConsoleScreenshot",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "agent_readonly" {
  name        = "${local.name_prefix}-agent-readonly"
  description = "Read-only EC2 discovery policy for the AI agent demo"
  policy      = data.aws_iam_policy_document.agent_readonly.json
}

# A dedicated IAM user stands in for the agent's identity. Deliberately no
# aws_iam_access_key resource here — this lab does not want a secret access
# key sitting in tfstate. If you actually wire an agent up to this account,
# generate short-lived credentials by hand (or better, use an assumable role
# with STS) and never commit them.
resource "aws_iam_user" "agent" {
  name = "${local.name_prefix}-agent"

  tags = {
    Name = "${local.name_prefix}-agent"
  }
}

resource "aws_iam_user_policy_attachment" "agent_readonly" {
  user       = aws_iam_user.agent.name
  policy_arn = aws_iam_policy.agent_readonly.arn
}
