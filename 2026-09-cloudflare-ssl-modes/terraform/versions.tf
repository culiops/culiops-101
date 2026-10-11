terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # --- Remote State (S3 Backend) -------------------------------------------
  # Left local for the lab. Uncomment + fill in for a shared/team run.
  #
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "labs/cloudflare-ssl-modes/terraform.tfstate"
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
      Lab         = "cloudflare-ssl-modes"
    }
  }
}

# Reads the API token from the CLOUDFLARE_API_TOKEN environment variable (source ../.env).
# Terraform only touches ONE Cloudflare object: the proxied DNS record in the lab zone.
# Every SSL-mode change, and the Origin CA certificate, is done BY HAND in the demo.
provider "cloudflare" {}
