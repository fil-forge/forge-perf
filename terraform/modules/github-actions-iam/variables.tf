variable "repository" {
  description = "owner/repo whose workflows may assume these roles."
  type        = string
}

variable "repository_subject_prefix" {
  description = <<-EOT
    The `repo:` segment of the `sub` claim GitHub mints for this repository, without the event part. Read it rather than composing it:

        gh api /repos/<owner>/<repo>/actions/oidc/customization/sub -q .sub_claim_prefix
  EOT
  type        = string
}

variable "apply_environments" {
  description = "GitHub environments whose jobs may assume the apply role. Each must exist, with main as its only deployment branch and a required reviewer, before this trust is applied: GitHub creates a missing environment unprotected the first time any branch's job names it (docs/operations.md)."
  type        = list(string)
  default     = []
}

variable "account_id" {
  description = "Account the roles live in, used to scope IAM writes to the box roles. Passed in so a bootstrap run with the wrong credentials fails on allowed_account_ids."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every name this module creates or grants: <prefix>-ci-plan, <prefix>-box-*."
  type        = string
}

variable "state_bucket_name" {
  description = "The state bucket the plan and apply roles may use."
  type        = string
}

variable "state_key_prefixes" {
  description = "State key prefixes the CI roles may touch. Bootstrap state is left out: an operator applies it, so no CI role needs it."
  type        = list(string)
}

variable "results_bucket_name" {
  description = "The bucket holding raw/ and published/ run records."
  type        = string
}

variable "piri_bucket_name_prefix" {
  description = "Every piri bucket a box root creates starts with this and a hyphen."
  type        = string
}

variable "tag_key" {
  description = "Tag every resource OpenTofu creates for this project carries, through default_tags. On a resource without it the apply role may only describe, create in its own network, and tag at creation."
  type        = string
  default     = "Project"
}

variable "tag_value" {
  description = "Value of tag_key on this project's resources."
  type        = string
}

variable "region" {
  description = "Region of the boxes, their SSM parameters and the key SSM decrypts them with."
  type        = string
}

variable "ssm_path" {
  description = "SSM Parameter Store path a box may read, with a leading slash and no trailing one."
  type        = string
}

variable "image_owners" {
  description = "ec2:Owner values a box image or its snapshot may carry. Canonical's public Ubuntu images evaluate as \"amazon\", not as Canonical's account ID; the account ID stays for anything that reports it."
  type        = list(string)
  default     = ["amazon", "099720109477"]
}

variable "box_instance_types" {
  description = "Instance type patterns the apply role may launch. A box type outside them needs this list changed in the same pull request."
  type        = list(string)
  default     = ["m9gd.*"]
}
