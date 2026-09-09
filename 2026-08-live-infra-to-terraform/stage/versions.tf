terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # ─── Remote State (S3 Backend) ─────────────────────────────────────────────
  # Left commented out for local lab use. Uncomment + fill in before running
  # this against a shared/long-lived environment.
  #
  # backend "s3" {
  #   bucket         = "culiops-terraform-state"
  #   key            = "labs/adopt-clickops-ec2/stage/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  #   kms_key_id     = "alias/terraform-state"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Lab         = "adopt-clickops-ec2"
      # Deliberately NO LabRoot/stage-vs-adopt tag here: adopt/'s provider
      # must produce byte-identical default_tags, or the SG/instance import
      # would show a spurious tag diff alongside the ami diff this lab is
      # actually about.
    }
  }
}
