##############################################
# main.tf — Provider + backend configuration
##############################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 — uncomment and fill in after creating the bucket
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "hardened-ec2/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-lock"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Owner       = var.stack_owner
      ManagedBy   = "Terraform"
      Project     = "HardenedEC2"
    }
  }
}

# Used throughout — first AZ in the chosen region
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = data.aws_availability_zones.available.names[0]
}
