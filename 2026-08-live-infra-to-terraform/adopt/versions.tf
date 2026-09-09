terraform {
  required_version = ">= 1.5" # native `import {}` blocks require 1.5+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # ─── Remote State (S3 Backend) ─────────────────────────────────────────────
  # Left commented out for local lab use.
  #
  # backend "s3" {
  #   bucket         = "culiops-terraform-state"
  #   key            = "labs/adopt-clickops-ec2/adopt/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  #   kms_key_id     = "alias/terraform-state"
  # }
}

provider "aws" {
  region = var.aws_region

  # Must match stage's default_tags (Project/Environment/ManagedBy) so the
  # imported resources don't show a spurious tag diff alongside the AMI
  # diff this lab is actually about. Fill project_name/environment from
  # `cd ../stage && terraform output` the same way you fill the *_id vars.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Lab         = "adopt-clickops-ec2"
      # Must exactly mirror stage's default_tags — see the comment there.
    }
  }
}
