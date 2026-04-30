terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial backend config — supply bucket + region via -backend-config flags
  # or TF_CLI_ARGS_init env var. Key is fixed to this workspace path.
  # Local runs: terraform init -backend-config="bucket=<bucket>" -backend-config="region=us-east-1"
  # Migrate existing local state: add -migrate-state on the first init after adding this block.
  backend "s3" {
    key = "vaniam-ai/terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}
