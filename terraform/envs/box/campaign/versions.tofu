terraform {
  required_version = ">= 1.12"

  backend "s3" {
    bucket       = "forge-perf-tfstate-654654381893"
    key          = "box/campaign.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
