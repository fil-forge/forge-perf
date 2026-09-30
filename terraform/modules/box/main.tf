# One forge-perf box: the instance, its security group and role, and the six
# S3 buckets its piri writes to.
#
# The box holds no state worth keeping. Everything it measures with comes from
# this repository and the pinned images, and every run's output leaves for the
# results bucket before the next run starts, so replacing the instance costs
# one boot and a cold image pull. The piri buckets are emptied after every run
# and carry force_destroy for the same reason.

module "constants" {
  source = "../shared/constants"
}

locals {
  name = "forge-perf-box-${var.box_name}"

  # A campaign box started to measure the ceilings (campaign.json's mode).
  calibration = var.mode == "campaign" && try(jsondecode(var.campaign).mode, "") == "calibration"

  # The apply role may change only what carries Project=forge-perf, so every
  # resource must get it at creation. Each sets it in its own tags as well as
  # through the root's provider: a test's provider block replaces the root's,
  # so only the resources' own tags are visible to the tests.
  tags = {
    Project = "forge-perf"
    Box     = var.box_name
  }
  account_id = module.constants.nonprod_account_id
  region     = module.constants.region
  results    = "arn:aws:s3:::${module.constants.results_bucket_name}"
  requests   = "arn:aws:s3:::${module.constants.requests_bucket_name}"

  # smelt appends the node name to the manifest's bucket_prefix, and piri its
  # store: forge-perf-piri-<box>-<account>-piri-0-<store>. The longest name,
  # campaign's consolidation bucket, is 58 characters.
  smelt_bucket_prefix = "${module.constants.piri_bucket_name_prefix}-${var.box_name}-${local.account_id}-"
  piri_bucket_prefix  = "${local.smelt_bucket_prefix}piri-0-"
  # piri/pkg/fx/store/s3/provider.go:48-96. Blob bytes land in pdp.
  piri_stores = ["allocations", "acceptances", "claims", "receipts", "pdp", "consolidation"]

  ec2_architecture = var.architecture == "amd64" ? "x86_64" : "arm64"

  # No instance type here: the host reads it from instance metadata, so a
  # resize leaves user_data alone and stays an in-place stop, modify and start.
  bootstrap = templatefile("${path.module}/files/bootstrap.sh.tftpl", {
    box_id              = var.box_name
    mode                = var.mode
    repository_url      = var.repository_url
    ref                 = var.forge_perf_ref
    region              = local.region
    results_bucket      = module.constants.results_bucket_name
    piri_bucket_prefix  = local.piri_bucket_prefix
    smelt_bucket_prefix = local.smelt_bucket_prefix
    ssm_path            = module.constants.ssm_path
    campaign_json       = var.campaign == null ? "" : var.campaign
    # The persistent box has no ExpiresAt, so its user data has no timer.
    expire_calendar = var.expires_at == null ? "" : formatdate("YYYY-MM-DD hh:mm:ss", var.expires_at)
  })
}

data "aws_vpc" "default" {
  default = true
}

# Created by the network root and found by its tag, so this root reads no other
# root's state.
data "aws_subnet" "perf" {
  vpc_id = data.aws_vpc.default.id

  filter {
    name   = "tag:Name"
    values = [module.constants.subnet_name]
  }
}

# The pinned image, read back only to check it against the architecture.
# Canonical's images are deprecated two years after release, and a filtered
# lookup leaves deprecated images out; the pin is kept on purpose.
data "aws_ami" "pinned" {
  owners             = ["099720109477"]
  include_deprecated = true

  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

data "aws_ec2_instance_type" "box" {
  instance_type = var.instance_type
}

# ---------------------------------------------------------------------------
# Network

# No ingress. Session Manager is the only way in, and its agent dials out, as
# on infra-nodes' dev node (infra-nodes/terraform/modules/node/main.tf:62-65).
#
# Keep name and description fixed: changing either replaces the group, and
# attaching the replacement modifies the box's network interface, which
# carries no Project tag, so the apply role is denied.
resource "aws_security_group" "box" {
  name        = local.name
  description = "forge-perf box ${var.box_name}: nothing in, everything out"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(local.tags, { Name = local.name })
}

# Image pulls, GitHub, Session Manager, Go modules, and S3 through the gateway
# endpoint.
resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.box.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Instance role

# The apply role may create this role only with the box permissions boundary,
# which caps it whatever the policies below say.
resource "aws_iam_role" "box" {
  name                 = local.name
  permissions_boundary = "arn:aws:iam::${local.account_id}:policy/forge-perf-box-boundary"
  tags                 = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.box.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "box" {
  # AmazonSSMManagedInstanceCore reads every parameter in the account,
  # infra-central's dev secrets included (infra-nodes/terraform/modules/node/main.tf:123-126).
  statement {
    sid           = "DenyOtherParameters"
    effect        = "Deny"
    actions       = ["ssm:GetParameter*"]
    not_resources = ["arn:aws:ssm:${local.region}:${local.account_id}:parameter${module.constants.ssm_path}/*"]
  }

  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${local.region}:${local.account_id}:parameter${module.constants.ssm_path}/*"]
  }

  statement {
    sid       = "DecryptParameters"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }

  # Write-only: a compromised box can overwrite its own records, which bucket
  # versioning keeps, and read nothing back. A campaign box in mode calibration
  # also measures the ceilings, whose evidence goes to raw/calibration/
  # (scripts/host/ceiling.sh); a box running a set cannot overwrite it.
  statement {
    sid     = "WriteOwnResults"
    actions = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = concat([
      "${local.results}/raw/${var.box_name}/*",
      "${local.results}/published/${var.box_name}/*",
    ], local.calibration ? ["${local.results}/raw/calibration/*"] : [])
  }

  # Only the persistent box runs /forge-perf experiments: it takes requests
  # from the queue and answers in status/ (docs/runner.md, "Experiments").
  dynamic "statement" {
    for_each = var.mode == "persistent" ? [1] : []

    content {
      sid       = "ListRequests"
      actions   = ["s3:ListBucket"]
      resources = [local.requests]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["requests/*"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.mode == "persistent" ? [1] : []

    content {
      sid       = "TakeRequests"
      actions   = ["s3:GetObject", "s3:DeleteObject"]
      resources = ["${local.requests}/requests/*"]
    }
  }

  dynamic "statement" {
    for_each = var.mode == "persistent" ? [1] : []

    content {
      sid       = "AnswerRequests"
      actions   = ["s3:PutObject"]
      resources = ["${local.requests}/status/*"]
    }
  }

  # The wipe empties the buckets after every run. Reading and writing objects
  # is piri's, through its own key.
  statement {
    sid = "EmptyOwnPiriBuckets"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = flatten([
      for s in local.piri_stores : [
        "arn:aws:s3:::${local.piri_bucket_prefix}${s}",
        "arn:aws:s3:::${local.piri_bucket_prefix}${s}/*",
      ]
    ])
  }
}

resource "aws_iam_role_policy" "box" {
  name   = "box"
  role   = aws_iam_role.box.id
  policy = data.aws_iam_policy_document.box.json
}

resource "aws_iam_instance_profile" "box" {
  name = local.name
  role = aws_iam_role.box.name
  tags = local.tags
}

# ---------------------------------------------------------------------------
# Instance

resource "aws_instance" "box" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.perf.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.box.id]
  iam_instance_profile        = aws_iam_instance_profile.box.name

  # IMDSv2 with a hop limit of 1, as infra-nodes: containers on Docker's
  # bridge cannot reach the instance's credentials. Only host scripts use them.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true

    # The apply role needs Project to manage the volume.
    tags = merge(local.tags, { Name = local.name })
  }

  # Carries no instance type (see local.bootstrap).
  user_data = local.bootstrap

  # Bootstrap runs once, so a change to it reaches the box as a replacement.
  # The box is stateless, and one boot is the whole cost. There is no
  # ignore_changes on ami: the image is pinned, and a new one is a reviewed
  # change that should replace the box.
  user_data_replace_on_change = true

  lifecycle {
    precondition {
      condition     = data.aws_ami.pinned.architecture == local.ec2_architecture
      error_message = "ami_id is ${data.aws_ami.pinned.architecture}, architecture is ${var.architecture}."
    }

    precondition {
      condition     = contains(data.aws_ec2_instance_type.box.supported_architectures, local.ec2_architecture)
      error_message = "${var.instance_type} does not run ${var.architecture}."
    }

    # The NVMe unit formats the instance store at every boot, and a type
    # without one would put every run on the root volume.
    precondition {
      condition     = data.aws_ec2_instance_type.box.instance_storage_supported
      error_message = "${var.instance_type} has no instance store."
    }
  }

  tags = merge(
    local.tags,
    { Name = local.name },
    var.expires_at == null ? {} : { ExpiresAt = var.expires_at },
  )
}

# ---------------------------------------------------------------------------
# piri's buckets

# Pre-created, so piri finds them and never calls MakeBucket: its key needs no
# CreateBucket, and the settings below come from code.
resource "aws_s3_bucket" "piri" {
  for_each = toset(local.piri_stores)
  bucket   = "${local.piri_bucket_prefix}${each.key}"

  # Run data only, and destroying a campaign box must not stall on objects.
  force_destroy = true

  tags = local.tags
}

resource "aws_s3_bucket_public_access_block" "piri" {
  for_each = toset(local.piri_stores)
  bucket   = aws_s3_bucket.piri[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "piri" {
  for_each = toset(local.piri_stores)
  bucket   = aws_s3_bucket.piri[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The wipe empties the buckets after every run. This caps the cost of a wipe
# that failed. S3 expires an object at the first UTC midnight at least a day
# after it was written, so it cannot reach into a live run.
resource "aws_s3_bucket_lifecycle_configuration" "piri" {
  for_each = toset(local.piri_stores)
  bucket   = aws_s3_bucket.piri[each.key].id

  rule {
    id     = "safety-net"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
