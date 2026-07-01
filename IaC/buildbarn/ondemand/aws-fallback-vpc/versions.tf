terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local state on purpose: this is a tiny, standalone, rarely-changed VPC that
  # lives next to the buildfarm code, NOT in percona-cd-platform. If this graduates
  # past PoC, move state to the team's S3 backend.
}

provider "aws" {
  region = var.region
}
