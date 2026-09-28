# The persistent box.
#
# Applied by deploy.yml's apply-box-main when the plan on a push to main is not
# empty, after a reviewer approves in the box-change environment. A resize or
# replacement loses a run in progress, so the approval waits until no run is
# active (docs/operations.md, "The persistent box").

provider "aws" {
  region              = module.constants.region
  allowed_account_ids = [module.constants.nonprod_account_id]

  # The apply role may change only what carries Project=forge-perf.
  default_tags {
    tags = {
      Project = "forge-perf"
      Box     = "main"
    }
  }
}

module "constants" {
  source = "../../../modules/shared/constants"
}

variable "instance_type" {
  description = "The tier: m9gd.8xlarge since gate 1 lit on 2026-09-28, m9gd.2xlarge before."
  type        = string
}

variable "architecture" {
  description = "Must match the pinned AMI."
  type        = string
}

module "box" {
  source = "../../../modules/box"

  box_name      = "main"
  mode          = "persistent"
  instance_type = var.instance_type
  architecture  = var.architecture
  ami_id        = module.constants.ami_id
}

output "instance_id" {
  value = module.box.instance_id
}

output "ami_id" {
  value = module.box.ami_id
}

output "piri_bucket_prefix" {
  value = module.box.piri_bucket_prefix
}
