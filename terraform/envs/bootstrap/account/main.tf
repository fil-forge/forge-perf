# Bootstrap for the dev account: the state bucket every other root in this
# repository keeps its state in, the roles GitHub Actions assumes, the results
# bucket, piri's IAM user and the cost budget.
#
# It lives in its own root because of a chicken-and-egg problem. The bucket is
# what every other root's backend points at, so it cannot be created by an
# apply that already keeps its state there, and the CI roles cannot be created
# by the CI they authorize. So this root is applied by hand and everything
# downstream of it is ordinary. versions.tofu gives the first-apply procedure.
#
# The results bucket and the piri user live here too, so no CI role ever holds
# write access to raw results or to an IAM user.

provider "aws" {
  region = module.constants.region

  # A bucket created in the wrong account is invisible until another root fails
  # to reach it, so name the account this root belongs to and let a mismatch
  # fail at plan time instead.
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-perf"
    }
  }
}

module "constants" {
  source = "../../../modules/shared/constants"
}

locals {
  # Hard-coded in every backend block in this repository, so it cannot be
  # derived there the way it is here. Stated in the same shape those blocks
  # state it, and guarded by allowed_account_ids above.
  state_bucket_name = "${module.constants.state_bucket_name_prefix}-${module.constants.nonprod_account_id}"

  results_role_arn = "arn:aws:iam::${module.constants.nonprod_account_id}:role/forge-perf-ci-results"
}

module "tfstate" {
  source = "../../../modules/tfstate"

  bucket_name = local.state_bucket_name
}

output "state_bucket_name" {
  value = module.tfstate.bucket_name
}

module "github_actions_iam" {
  source = "../../../modules/github-actions-iam"

  repository = "fil-forge/forge-perf"

  # Read from the repository, not composed from its name:
  #   gh api /repos/fil-forge/forge-perf/actions/oidc/customization/sub -q .sub_claim_prefix
  repository_subject_prefix = "repo:fil-forge@280998881/forge-perf@1388269703"

  # The box roots apply in this environment. It must exist, with a required
  # reviewer and main as its only deployment branch, before this is applied
  # (docs/operations.md).
  apply_environments = ["box-change"]

  account_id  = module.constants.nonprod_account_id
  region      = module.constants.region
  ssm_path    = module.constants.ssm_path
  name_prefix = "forge-perf"
  tag_value   = "forge-perf"

  # The name rather than the tfstate module's output, so the policies are
  # known at plan time on the first apply, before the bucket exists.
  state_bucket_name       = local.state_bucket_name
  state_key_prefixes      = ["network", "box"]
  results_bucket_name     = module.constants.results_bucket_name
  piri_bucket_name_prefix = module.constants.piri_bucket_name_prefix
}

output "ci_role_arns" {
  description = "Literal role ARNs for the workflow env blocks."
  value       = module.github_actions_iam.role_arns
}

output "box_permissions_boundary_arn" {
  description = "permissions_boundary for every box instance role."
  value       = module.github_actions_iam.box_permissions_boundary_arn
}

# ---------------------------------------------------------------------------
# Results bucket.
#
# raw/<box>/<run_id>/ holds the full run directory and never leaves this
# bucket; published/<box>/ holds the allowlisted records the page reads. Boxes
# write both through their instance roles; forge-perf-ci-results reads
# published/ only.

resource "aws_s3_bucket" "results" {
  bucket = module.constants.results_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

# A record overwritten by a compromised box stays recoverable.
resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Git on the results branch is the durable record, so published/ needs only to
# outlast a publishing workflow broken for weeks.
resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket     = aws_s3_bucket.results.id
  depends_on = [aws_s3_bucket_versioning.results]

  dynamic "rule" {
    for_each = { raw = 180, published = 90 }

    content {
      id     = "expire-${rule.key}"
      status = "Enabled"

      filter {
        prefix = "${rule.key}/"
      }

      expiration {
        days = rule.value
      }

      noncurrent_version_expiration {
        noncurrent_days = 30
      }

      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }
    }
  }
}

# Backs up the role's own policy: an explicit deny cannot be undone by a later
# grant on the role. Both statements name the results role through
# aws:PrincipalArn rather than as the principal, so recreating the role does
# not leave the policy naming a deleted role's unique id.
data "aws_iam_policy_document" "results_bucket" {
  statement {
    sid       = "ResultsRoleNeverReadsRaw"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${module.constants.results_bucket_name}/raw/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.results_role_arn]
    }
  }

  # A listing is authorized on the bucket, not on raw/, so the deny above does
  # not cover it. A listing with no prefix is denied too.
  statement {
    sid       = "ResultsRoleListsPublishedOnly"
    effect    = "Deny"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = ["arn:aws:s3:::${module.constants.results_bucket_name}"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.results_role_arn]
    }

    condition {
      test     = "StringNotLike"
      variable = "s3:prefix"
      values   = ["published/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket     = aws_s3_bucket.results.id
  policy     = data.aws_iam_policy_document.results_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.results]
}

# ---------------------------------------------------------------------------
# piri's S3 identity.
#
# piri accepts only a static key pair. The key is created by hand (see
# docs/operations.md), because aws_iam_access_key would put the secret in state
# and the plan role reads state from pull requests. One user serves both boxes;
# the per-box bucket prefix keeps their data apart.

data "aws_vpc" "default" {
  default = true
}

resource "aws_iam_user" "piri" {
  name = "forge-perf-piri"
}

# The source condition makes the key usable only from inside the default VPC,
# where S3 traffic from the forge-perf subnet goes through the gateway
# endpoint. Once the network root has created that endpoint, this narrows to
# aws:SourceVpce, which also excludes infra-nodes' dev node in the same VPC.
data "aws_iam_policy_document" "piri" {
  statement {
    sid       = "PiriBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = ["arn:aws:s3:::${module.constants.piri_bucket_name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpc"
      values   = [data.aws_vpc.default.id]
    }
  }

  statement {
    sid = "PiriObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::${module.constants.piri_bucket_name_prefix}-*/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpc"
      values   = [data.aws_vpc.default.id]
    }
  }
}

resource "aws_iam_user_policy" "piri" {
  name   = "piri-buckets"
  user   = aws_iam_user.piri.name
  policy = data.aws_iam_policy_document.piri.json
}

# ---------------------------------------------------------------------------
# Cost budget on the Project tag. The filter matches nothing until Project is
# activated as a cost allocation tag in Billing (docs/operations.md).

variable "budget_monthly_usd" {
  description = "Monthly spend on Project=forge-perf that triggers the alerts. Tier 1 runs about $395 a month, tier 2 about $1,500 plus campaigns."
  type        = number
}

variable "budget_alert_email" {
  description = "Recipient of the budget alerts. Kept out of the committed tfvars; pass it as TF_VAR_budget_alert_email."
  type        = string
}

resource "aws_sns_topic" "budget" {
  name = "forge-perf-budget"
}

data "aws_iam_policy_document" "budget_topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.budget.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [module.constants.nonprod_account_id]
    }
  }
}

resource "aws_sns_topic_policy" "budget" {
  arn    = aws_sns_topic.budget.arn
  policy = data.aws_iam_policy_document.budget_topic.json
}

# AWS sends a confirmation link; alerts arrive only after it is followed.
resource "aws_sns_topic_subscription" "budget" {
  topic_arn = aws_sns_topic.budget.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_budgets_budget" "forge_perf_monthly" {
  name         = "forge-perf-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_monthly_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$forge-perf"]
  }

  dynamic "notification" {
    for_each = ["ACTUAL", "FORECASTED"]

    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = 100
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value
      subscriber_sns_topic_arns = [aws_sns_topic.budget.arn]
    }
  }

  depends_on = [aws_sns_topic_policy.budget]
}
