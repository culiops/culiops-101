# main.tf — Cloudflare Origin Lockdown lab
#
# Provisions a deliberately-exposed origin behind Cloudflare, then locks it down
# in two layers, all driven by var.protection ("none" -> "ip_allowlist" -> "aop").
#
# Resources:
#   AWS         — minimal VPC + public subnet + IGW, one EC2 origin (nginx), EIP, security group
#   Cloudflare  — proxied A record, SSL mode = Full, Authenticated Origin Pulls (global) toggle
#
# Teardown: `terraform destroy` (reverts the A record, the AOP toggle, and the SSL setting too).

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

# Cloudflare's published IPv4 ranges — the exact list the video curls by hand.
# Used to build the Layer 1 allowlist. (https://www.cloudflare.com/ips-v4)
data "http" "cloudflare_ips_v4" {
  url = "https://www.cloudflare.com/ips-v4"
}

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  cloudflare_ipv4 = toset(compact(split("\n", data.http.cloudflare_ips_v4.response_body)))

  # Layer 1 restricts 80/443 to Cloudflare only; every other state is wide open
  # (state "none" = the mistake; state "aop" reopens the SG so the mTLS 403 is
  # reachable and demonstrable — the lock has moved to the TLS layer, not the network).
  web_ingress_cidrs = var.protection == "ip_allowlist" ? local.cloudflare_ipv4 : toset(["0.0.0.0/0"])
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

# ─── Security group — the network-layer lock (Layer 1) ─────────────────────────

resource "aws_security_group" "origin" {
  name        = "${local.name_prefix}-origin"
  description = "Origin web server - ingress driven by protection var"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "${local.name_prefix}-origin" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = local.web_ingress_cidrs
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
  description       = "HTTPS from ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = local.web_ingress_cidrs
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
  description       = "HTTP from ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count             = var.ssh_ingress_cidr != "" ? 1 : 0
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_ingress_cidr
  description       = "SSH for inspection"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.origin.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All egress"
}

# ─── Origin instance + stable public IP ───────────────────────────────────────

resource "aws_instance" "origin" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.origin.id]
  key_name               = var.key_name != "" ? var.key_name : null

  # user_data depends ONLY on whether mTLS is on, so switching none <-> ip_allowlist
  # (a pure security-group change) does NOT rebuild the box — only enabling AOP, which
  # genuinely changes the nginx config, replaces the instance (immutable infra).
  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    aop_enabled     = var.protection == "aop"
    origin_hostname = var.origin_hostname
  })
  user_data_replace_on_change = true

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

# ─── Cloudflare — the edge in front of the origin ─────────────────────────────

# Proxied A record: the orange cloud. Traffic to the hostname hits Cloudflare;
# the origin's real IP is the EIP (which is exactly what leaks and gets hit directly).
resource "cloudflare_dns_record" "origin" {
  zone_id = var.cloudflare_zone_id
  name    = var.origin_hostname
  type    = "A"
  content = aws_eip.origin.public_ip
  ttl     = 1 # 1 = automatic; required while proxied
  proxied = true
  comment = "cloudflare-origin-lockdown lab - safe to delete"
}

# AOP precondition: SSL/TLS mode must be Full or Full (strict).
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "full"
}

# Layer 2, Cloudflare side: GLOBAL Authenticated Origin Pulls. This makes Cloudflare
# present its shared origin-pull certificate (the CA the origin trusts, fetched in
# cloud-init) on connections to every proxied host in the zone. Enabled only in "aop".
#
# NOTE: Global AOP is the `tls_client_auth` ZONE SETTING (uses Cloudflare's shared cert)
# — NOT the `cloudflare_authenticated_origin_pulls_settings` resource, which is ZONE-LEVEL
# AOP and requires you to upload your OWN certificate. Global AOP therefore needs only
# Zone Settings:Edit on the token, not SSL and Certificates:Edit.
resource "cloudflare_zone_setting" "aop" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "tls_client_auth"
  value      = var.protection == "aop" ? "on" : "off"
}
