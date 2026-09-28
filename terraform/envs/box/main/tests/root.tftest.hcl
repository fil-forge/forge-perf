# The persistent box root's own wiring: its tfvars and the pinned AMI reach
# the box module. box.tftest.hcl checks what the module creates.

provider "aws" {
  region                      = "us-east-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  default_tags {
    tags = { Project = "forge-perf", Box = "main" }
  }
}

run "root" {
  command = plan

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

  assert {
    condition = alltrue([
      output.piri_bucket_prefix == "forge-perf-piri-main-654654381893-piri-0-",
      var.instance_type == "m9gd.8xlarge",
      var.architecture == "arm64",
      output.ami_id == module.constants.ami_id,
    ])
    error_message = "the root builds box main at tier 2, arm64, on the constants' pinned AMI"
  }
}
