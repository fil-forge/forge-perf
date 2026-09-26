# What the box module creates for the persistent box, checked on the plan.
#
# Placeholder credentials and every lookup overridden, so it needs no AWS
# account: `tofu test` in this directory. Each run plans the module alone with
# the root's values; root.tftest.hcl checks the root's own wiring.

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
  values = { supported_architectures = ["arm64"], instance_storage_supported = true }
}

run "instance" {
  command = plan

  module {
    source = "../../../modules/box"
  }

  assert {
    condition = alltrue([
      aws_instance.box.ami == "ami-03e774c3214166a53",
      aws_instance.box.instance_type == "m9gd.2xlarge",
      aws_instance.box.subnet_id == "subnet-0test",
      aws_instance.box.associate_public_ip_address == true,
      aws_instance.box.user_data_replace_on_change == true,
    ])
    error_message = "the box runs the pinned AMI at tier 1 in the forge-perf subnet with a public address for egress"
  }

  assert {
    condition = alltrue([
      aws_instance.box.metadata_options[0].http_tokens == "required",
      aws_instance.box.metadata_options[0].http_put_response_hop_limit == 1,
    ])
    error_message = "instance metadata is IMDSv2 only with a hop limit of 1, out of the containers' reach"
  }

  assert {
    condition = alltrue([
      aws_instance.box.root_block_device[0].volume_type == "gp3",
      aws_instance.box.root_block_device[0].volume_size == 100,
      aws_instance.box.root_block_device[0].encrypted == true,
    ])
    error_message = "the root volume is 100 GB of encrypted gp3"
  }

  assert {
    condition = alltrue([
      aws_instance.box.tags["Project"] == "forge-perf",
      aws_instance.box.tags["Box"] == "main",
      aws_instance.box.tags["Name"] == "forge-perf-box-main",
      aws_instance.box.root_block_device[0].tags["Project"] == "forge-perf",
      aws_security_group.box.tags["Project"] == "forge-perf",
      !contains(keys(aws_instance.box.tags), "ExpiresAt"),
    ])
    error_message = "the persistent box is tagged Project, Box and Name, and never ExpiresAt, which the reaper acts on"
  }

  assert {
    condition = alltrue([
      aws_vpc_security_group_egress_rule.all_ipv4.cidr_ipv4 == "0.0.0.0/0",
      aws_security_group.box.name == "forge-perf-box-main",
    ])
    error_message = "the security group lets everything out"
  }
}

run "bootstrap" {
  command = plan

  module {
    source = "../../../modules/box"
  }

  assert {
    condition = alltrue([for line in [
      "FORGE_PERF_BOX_ID=main",
      "FORGE_PERF_MODE=persistent",
      "FORGE_PERF_CHECKOUT=/opt/forge-perf",
      "FORGE_PERF_REF=main",
      "FORGE_PERF_REGION=us-east-2",
      "FORGE_PERF_RESULTS_BUCKET=forge-perf-results-654654381893",
      "FORGE_PERF_PIRI_BUCKET_PREFIX=forge-perf-piri-main-654654381893-piri-0-",
      "FORGE_PERF_SMELT_BUCKET_PREFIX=forge-perf-piri-main-654654381893-",
      "FORGE_PERF_SSM_PATH=/forge-perf",
    ] : strcontains(aws_instance.box.user_data, "\n${line}\n")])
    error_message = "box.conf names the box, its mode, ref, buckets and parameter path"
  }

  assert {
    condition = alltrue([
      strcontains(aws_instance.box.user_data, "git clone --no-checkout 'https://github.com/fil-forge/forge-perf.git'"),
      strcontains(aws_instance.box.user_data, "\n\"$CHECKOUT/scripts/host/update.sh\" --local\n"),
      endswith(aws_instance.box.user_data, "date -Is >/etc/forge-perf/bootstrap-complete\n"),
    ])
    error_message = "bootstrap clones forge-perf, hands off to update.sh --local, and marks completion last"
  }
}

# A resize changes the instance type and nothing in user_data, so the provider
# stops, modifies and starts the same instance instead of replacing it.
run "resize" {
  command = plan

  module {
    source = "../../../modules/box"
  }

  variables {
    instance_type = "m9gd.8xlarge"
  }

  assert {
    condition = alltrue([
      aws_instance.box.instance_type == "m9gd.8xlarge",
      !strcontains(aws_instance.box.user_data, "m9gd"),
    ])
    error_message = "the rendered bootstrap does not depend on the instance type"
  }
}

run "role" {
  command = plan

  module {
    source = "../../../modules/box"
  }

  assert {
    condition = alltrue([
      aws_iam_role.box.name == "forge-perf-box-main",
      aws_iam_role.box.permissions_boundary == "arn:aws:iam::654654381893:policy/forge-perf-box-boundary",
      aws_iam_role_policy_attachment.ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
      aws_iam_instance_profile.box.name == "forge-perf-box-main",
      aws_iam_role.box.tags["Project"] == "forge-perf",
      aws_iam_instance_profile.box.tags["Project"] == "forge-perf",
    ])
    error_message = "the role carries the box boundary, which the apply role requires, and Session Manager's managed policy"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.box.policy).Statement :
      !contains(flatten([s.Action]), "s3:GetObject") && !contains(flatten([s.Action]), "s3:DeleteObject") || s.Sid == "EmptyOwnPiriBuckets"
    ])
    error_message = "the box reads no object anywhere and deletes only in its piri buckets"
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.box.policy).Statement : flatten([s.Resource]) if s.Sid == "WriteOwnResults"
      ])) == toset([
      "arn:aws:s3:::forge-perf-results-654654381893/raw/main/*",
      "arn:aws:s3:::forge-perf-results-654654381893/published/main/*",
    ])
    error_message = "the box writes its own raw/ and published/ prefixes and no other box's"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.box.policy).Statement :
      s.Effect == "Deny" && flatten([s.NotResource]) == ["arn:aws:ssm:us-east-2:654654381893:parameter/forge-perf/*"] if s.Sid == "DenyOtherParameters"
    ])
    error_message = "parameters outside /forge-perf are denied, including those the managed policy grants"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.box.policy).Statement : alltrue([
        for r in flatten([s.Resource]) : startswith(r, "arn:aws:s3:::forge-perf-piri-main-654654381893-piri-0-")
      ]) if s.Sid == "EmptyOwnPiriBuckets"
    ])
    error_message = "the box empties only its own piri buckets"
  }
}

run "buckets" {
  command = plan

  module {
    source = "../../../modules/box"
  }

  assert {
    condition = toset([for b in aws_s3_bucket.piri : b.bucket]) == toset([
      for s in ["allocations", "acceptances", "claims", "receipts", "pdp", "consolidation"] :
      "forge-perf-piri-main-654654381893-piri-0-${s}"
    ])
    error_message = "the six stores piri opens, under the name smelt gives node piri-0"
  }

  assert {
    condition = alltrue(concat(
      [for b in aws_s3_bucket.piri : b.force_destroy && b.tags["Project"] == "forge-perf"],
      [for p in aws_s3_bucket_public_access_block.piri : p.block_public_acls && p.block_public_policy && p.ignore_public_acls && p.restrict_public_buckets],
      [for e in aws_s3_bucket_server_side_encryption_configuration.piri : one(one(e.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"],
      [for l in aws_s3_bucket_lifecycle_configuration.piri : l.rule[0].expiration[0].days == 1 && l.rule[0].abort_incomplete_multipart_upload[0].days_after_initiation == 1],
    ))
    error_message = "every piri bucket is private, SSE-S3, expires objects and uploads after a day, and is destroyed with its contents"
  }
}

run "wrong_architecture" {
  command = plan

  module {
    source = "../../../modules/box"
  }

  variables {
    architecture = "amd64"
  }

  expect_failures = [aws_instance.box]
}
