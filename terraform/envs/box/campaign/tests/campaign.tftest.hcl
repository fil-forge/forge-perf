# The campaign root's wiring: the dispatch's inputs reach the box as its
# ExpiresAt tag, its pinned commit and /etc/forge-perf/campaign.json, and bad
# inputs stop the plan. Placeholder credentials and every lookup overridden,
# so it needs no AWS account.

provider "aws" {
  region                      = "us-east-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  default_tags {
    tags = { Project = "forge-perf", Box = "campaign" }
  }
}

variables {
  instance_type  = "m9gd.2xlarge"
  expires_at     = "2026-10-01T14:00:00Z"
  forge_perf_sha = "1111111111111111111111111111111111111111"
  campaign = {
    mode     = "campaign"
    set      = "calibration/sets/shakedown.json"
    runs     = 2
    size     = "10GB"
    workers  = [16, 32]
    duration = "30m"
  }
}

override_data {
  target = module.box.data.aws_vpc.default
  values = { id = "vpc-0test" }
}

override_data {
  target = module.box.data.aws_subnet.perf
  values = { id = "subnet-0test" }
}

override_data {
  target = module.box.data.aws_ami.pinned
  values = { architecture = "arm64" }
}

override_data {
  target = module.box.data.aws_ec2_instance_type.box
  values = { supported_architectures = ["arm64"], instance_storage_supported = true }
}

run "campaign_box" {
  command = plan

  assert {
    condition = alltrue([
      module.box.piri_bucket_prefix == "forge-perf-piri-campaign-654654381893-piri-0-",
      length("${module.box.piri_bucket_prefix}consolidation") <= 63,
    ])
    error_message = "the campaign box has its own piri buckets, each name within S3's 63 characters"
  }

  assert {
    condition     = strcontains(module.box.user_data, "\nFORGE_PERF_MODE=campaign\n") && strcontains(module.box.user_data, "\nFORGE_PERF_REF=1111111111111111111111111111111111111111\n")
    error_message = "the box runs in campaign mode, pinned at the dispatched commit"
  }

  assert {
    condition = jsondecode(regex("campaign.json <<'CAMPAIGN'\n(.*)\nCAMPAIGN\n", module.box.user_data)[0]) == {
      mode           = "campaign"
      set            = "calibration/sets/shakedown.json"
      runs           = 2
      size           = "10GB"
      workers        = [16, 32]
      duration       = "30m"
      forge_perf_sha = "1111111111111111111111111111111111111111"
      expires_at     = "2026-10-01T14:00:00Z"
    }
    error_message = "user_data writes the inputs, the commit and ExpiresAt to /etc/forge-perf/campaign.json"
  }

  assert {
    condition     = endswith(module.box.user_data, "systemctl start --no-block forge-perf-final-flush.service\nsystemctl start --no-block forge-perf-campaign.service\n")
    error_message = "the bootstrap starts the shutdown flush and the campaign unit on the first boot"
  }

  assert {
    condition     = can(regex("(?s)\nsystemctl enable --now forge-perf-expire.timer\n.*\ntrap 'rc=\\$\\?; \\[ \"\\$rc\" -eq 0 \\] \\|\\| systemctl poweroff' EXIT\n.*\n  git clone ", module.box.user_data))
    error_message = "a campaign box's bootstrap powers off on a failure, from before its first step that can fail"
  }

  assert {
    condition     = can(regex("(?s)\nOnCalendar=2026-10-01 14:00:00 UTC\nPersistent=true\n.*\nsystemctl enable --now forge-perf-expire.timer\n.*\n  git clone ", module.box.user_data))
    error_message = "the bootstrap arms a persistent poweroff timer at ExpiresAt before any step that can fail"
  }

  assert {
    condition     = module.box.tags["ExpiresAt"] == "2026-10-01T14:00:00Z" && module.box.tags["Box"] == "campaign"
    error_message = "the instance carries Box=campaign and the ExpiresAt the reaper reads"
  }
}

run "type_outside_the_tiers" {
  command = plan
  variables { instance_type = "m7i.large" }
  expect_failures = [var.instance_type]
}

run "expiry_not_utc" {
  command = plan
  variables { expires_at = "2026-10-01 14:00" }
  expect_failures = [var.expires_at]
}

run "campaign_without_a_set" {
  command = plan
  variables {
    campaign = { mode = "campaign", set = "", runs = 1, size = "10GB", workers = [16], duration = "30m" }
  }
  expect_failures = [var.campaign]
}

run "too_many_runs" {
  command = plan
  variables {
    campaign = { mode = "campaign", set = "calibration/sets/a.json", runs = 21, size = "10GB", workers = [], duration = "30m" }
  }
  expect_failures = [var.campaign]
}

run "calibration_needs_no_set" {
  command = plan
  variables {
    campaign = { mode = "calibration", set = "", runs = 1, size = "1GB", workers = [], duration = "1m" }
  }

  assert {
    condition     = !strcontains(module.box.user_data, "systemctl poweroff' EXIT")
    error_message = "a calibration box stays up after a failed bootstrap, for the operator attached to it"
  }
}
