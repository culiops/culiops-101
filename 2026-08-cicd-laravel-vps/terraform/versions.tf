terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Remote state (S3) — commented out; uncomment + fill for team use.
  # backend "s3" {
  #   bucket = "culiops-terraform-state"
  #   key    = "labs/deploy-laravel-vps/terraform.tfstate"
  #   region = "ap-southeast-1"
  # }
}

provider "aws" {
  region = var.aws_region
}
