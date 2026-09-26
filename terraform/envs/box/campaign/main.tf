# The campaign box: a short-lived box beside the persistent one that runs one
# committed set a few times, publishes and powers off (docs/operations.md,
# "A campaign"). Also the box the ceiling measurements run on.
#
# Applied and destroyed only by campaign.yml; the hourly campaign-reaper.yml
# destroys it once it is past ExpiresAt or has been stopped for an hour. A
# separate root, so neither can ever plan against the persistent box.

provider "aws" {
  region              = module.constants.region
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-perf"
      Box     = "campaign"
    }
  }
}

module "constants" {
  source = "../../../modules/shared/constants"
}

variable "instance_type" {
  description = "One of the three tiers' types."
  type        = string

  validation {
    condition     = contains(["m9gd.2xlarge", "m9gd.8xlarge", "m9gd.16xlarge"], var.instance_type)
    error_message = "instance_type is m9gd.2xlarge, m9gd.8xlarge or m9gd.16xlarge."
  }
}

variable "architecture" {
  description = "Must match the pinned AMI."
  type        = string
  default     = "arm64"
}

variable "expires_at" {
  description = "UTC time the box powers itself off and the reaper destroys it: the dispatch time plus 1 to 24 hours."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.expires_at))
    error_message = "expires_at is YYYY-MM-DDTHH:MM:SSZ."
  }
}

variable "forge_perf_sha" {
  description = "The forge-perf commit the box clones and stays at: the commit campaign.yml was dispatched on."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.forge_perf_sha))
    error_message = "forge_perf_sha is a full commit SHA."
  }
}

variable "campaign" {
  description = "What the box does. mode campaign runs the set; mode calibration boots and waits for the ceiling measurements."
  type = object({
    mode     = string
    set      = string
    runs     = number
    size     = string
    workers  = list(number)
    duration = string
  })

  validation {
    condition = contains(["campaign", "calibration"], var.campaign.mode) && (
      var.campaign.mode == "calibration" || can(regex("^calibration/sets/[A-Za-z0-9._-]+\\.json$", var.campaign.set))
    )
    error_message = "mode is campaign or calibration; a campaign names a set under calibration/sets/."
  }

  validation {
    condition = (
      var.campaign.runs >= 1 && var.campaign.runs <= 20 && floor(var.campaign.runs) == var.campaign.runs &&
      can(regex("^[1-9][0-9]*GB$", var.campaign.size)) && can(regex("^[1-9][0-9]*[smh]$", var.campaign.duration)) &&
      length(var.campaign.workers) <= 8 && alltrue([for w in var.campaign.workers : w >= 1 && w <= 1024 && floor(w) == w])
    )
    error_message = "runs is 1 to 20, size like 100GB, duration like 30m, and workers up to 8 whole numbers from 1 to 1024."
  }
}

module "box" {
  source = "../../../modules/box"

  box_name       = "campaign"
  mode           = "campaign"
  instance_type  = var.instance_type
  architecture   = var.architecture
  ami_id         = module.constants.ami_id
  expires_at     = var.expires_at
  forge_perf_ref = var.forge_perf_sha
  campaign = jsonencode(merge(var.campaign, {
    forge_perf_sha = var.forge_perf_sha
    expires_at     = var.expires_at
  }))
}

output "instance_id" {
  value = module.box.instance_id
}

output "piri_bucket_prefix" {
  value = module.box.piri_bucket_prefix
}
