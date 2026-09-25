# Values that more than one root module has to agree on.
#
# Root modules cannot share a variable, and a literal copied into several of
# them drifts. This module creates nothing, so any root can instantiate it for
# the cost of a `module` block.

output "nonprod_account_id" {
  description = "filone-sandbox, the dev account. It holds the boxes, the results bucket and this repository's state, next to infra-nodes' dev node and infra-central's dev stage."
  value       = "654654381893"
}

output "region" {
  description = "Home region for every forge-perf resource: the boxes, their subnet, piri's buckets, the results bucket and the state bucket."
  value       = "us-east-2"
}

output "state_bucket_name_prefix" {
  description = "First half of the state bucket name; the account id makes up the rest. Backend blocks cannot read a variable and spell the whole name out, but every root that creates or grants access to the bucket composes it from here. A bucket of its own keeps this repository's CI roles away from the other repositories' state in the same account."
  value       = "forge-perf-tfstate"
}

output "results_bucket_name" {
  description = "Where every run's record lands: raw/ holds the full run directory, private; published/ holds what the public page reads. Created by the bootstrap root, so no CI role can write raw results."
  value       = "forge-perf-results-654654381893"
}

output "piri_bucket_name_prefix" {
  description = "First part of the name of each piri bucket. A box root appends the box name, the account id and piri's own suffix, forge-perf-piri-<box>-654654381893-piri-0-<store>, which stays under S3's 63-character limit for every box and store."
  value       = "forge-perf-piri"
}

output "ssm_path" {
  description = "SSM Parameter Store path holding every secret a box reads at run time. The parameters are created by hand and never pass through OpenTofu, so no state file holds them."
  value       = "/forge-perf"
}

output "subnet_name" {
  description = "Name tag of the forge-perf subnet in the default VPC. The network root creates it and the box roots find it by this tag, so no root reads another's state."
  value       = "forge-perf"
}

output "ami_id" {
  description = "Canonical's Ubuntu 24.04 arm64 server image, release 20260904, gp3, in us-east-2. Pinned where infra-nodes looks its image up at create time: the kernel is part of the instrument, so a new image is a deliberate change with its own pull request, and a campaign box boots the same image as the persistent one."
  value       = "ami-03e774c3214166a53"
}
