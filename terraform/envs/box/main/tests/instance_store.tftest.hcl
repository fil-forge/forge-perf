# The box module refuses an instance type without instance storage, which the
# NVMe format and every run depend on. Its own file, so this lookup override
# is the only one for its address.

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

variables {
  box_name      = "main"
  mode          = "persistent"
  instance_type = "m9gd.2xlarge"
  architecture  = "arm64"
  ami_id        = "ami-03e774c3214166a53"
}

override_data {
  target = data.aws_vpc.default
  values = { id = "vpc-0test" }
}

override_data {
  target = data.aws_subnet.perf
  values = { id = "subnet-0test" }
}

override_data {
  target = data.aws_ami.pinned
  values = { architecture = "arm64" }
}

override_data {
  target = data.aws_ec2_instance_type.box
  values = { supported_architectures = ["arm64"], instance_storage_supported = false }
}

run "no_instance_store" {
  command = plan

  module {
    source = "../../../modules/box"
  }

  variables {
    instance_type = "m9g.2xlarge"
  }

  expect_failures = [aws_instance.box]
}
