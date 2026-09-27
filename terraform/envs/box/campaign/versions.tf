# This root is OpenTofu-only, and this file is how that is enforced.
#
# OpenTofu prefers versions.tofu over a versions.tf of the same name and never
# reads this one. Terraform does not recognise the .tofu extension at all, so it
# reads only this file and stops at the constraint below, which no release
# satisfies.
#
# The guard is not decorative. Terraform stamps its own version into the state
# file it writes, and Terraform's releases are numbered ahead of OpenTofu's, so
# one `terraform apply` here would leave a state that OpenTofu then refuses to
# read.
terraform {
  required_version = "< 0.0.0"
}
