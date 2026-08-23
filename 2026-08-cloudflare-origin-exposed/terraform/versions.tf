terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

# NOTE — no Cloudflare provider here on purpose.
# In this lab Terraform only stands up the AWS "stage" (the exposed origin). Everything on the
# Cloudflare side — the proxied DNS record, SSL mode, and Authenticated Origin Pulls — is done
# BY HAND during the demo (dashboard or `curl` to the Cloudflare API), because *watching those
# actions happen* is the lesson. Teardown of those by-hand artifacts lives in `cleanup.sh`.
