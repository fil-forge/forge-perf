terraform {
  required_version = ">= 1.12"

  # This root's own state, in the bucket this root creates. That circularity is
  # resolved once, the way infra-nodes resolves it (its docs/RUNBOOK.md, "The
  # state bucket, once per account"): comment out this backend block, run
  # `tofu init && tofu apply -var piri_key_via_s3_endpoint=false` against the
  # local backend, restore the block, then run `tofu init -migrate-state`. The
  # variable is needed until the network root's endpoint exists
  # (docs/operations.md, "The network root").
  backend "s3" {
    bucket       = "forge-perf-tfstate-654654381893"
    key          = "bootstrap/account.tfstate"
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
