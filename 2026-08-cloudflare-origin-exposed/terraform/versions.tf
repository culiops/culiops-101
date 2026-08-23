terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0" # v5 renamed many resources vs v4 (cloudflare_dns_record, etc.)
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # ─── Remote State (S3 Backend) ─────────────────────────────────────────────
  # Left local for the lab. Uncomment + fill in for a shared/team run.
  #
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "labs/cloudflare-origin-lockdown/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Lab         = "cloudflare-origin-lockdown"
    }
  }
}

# The Cloudflare provider reads the API token from the CLOUDFLARE_API_TOKEN
# environment variable automatically — no secret ever lands in a .tf/.tfvars file.
# The token needs, on the target zone, only two permissions:
#   DNS:Edit            (the proxied A record)
#   Zone Settings:Edit  (SSL mode + Global AOP via the tls_client_auth setting)
# Global AOP does NOT need "SSL and Certificates:Edit" — that is only for zone-level /
# per-hostname AOP, where you upload your own certificate.
provider "cloudflare" {}
