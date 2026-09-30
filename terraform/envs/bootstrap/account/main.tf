# Bootstrap for the dev account: the state bucket every other root in this
# repository keeps its state in, the roles GitHub Actions assumes, the results
# bucket and the dispatch that publishes each record, the waker that starts a
# sleeping box, piri's IAM user and the cost budget.
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

  # The service repositories whose pull requests may ask for a forge-perf run
  # with a /forge-perf comment (docs/operations.md): the four on the per-object
  # ingest path, each with the subject prefix GitHub mints for it, read from
  # the repository:
  #   gh api /repos/fil-forge/<repo>/actions/oidc/customization/sub -q .sub_claim_prefix
  # Only the main ref is trusted: issue_comment workflows run from there.
  request_repositories = {
    "ingot" = "repo:fil-forge/ingot"
    "piri"  = "repo:fil-forge/piri"
    "sprue" = "repo:fil-forge/sprue"
    "hilt"  = "repo:fil-forge/hilt"
  }
  request_subjects = sort(distinct(flatten([
    for repo, prefix in local.request_repositories : [
      "repo:fil-forge/${repo}:ref:refs/heads/main",
      "${prefix}:ref:refs/heads/main",
    ]
  ])))
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
  requests_bucket_name    = module.constants.requests_bucket_name
  request_subjects        = local.request_subjects
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
# Publishing on each record.
#
# GitHub starts publish.yml's schedule hours late, so a record landing in
# published/<box>/ dispatches publish.yml at once. The bucket sends its events
# to EventBridge, a rule keeps run records (published/<box>/<run_id>.json, never
# heartbeat.json), and an API destination posts the dispatch to GitHub. The
# schedule stays as the fallback.
#
# The GitHub token lives in the EventBridge connection, which this root creates
# with a placeholder. An operator sets the token by hand (docs/operations.md,
# "Publishing on each record"), so it never reaches this file or its state, and
# the box still holds no GitHub credential.

resource "aws_s3_bucket_notification" "results" {
  bucket      = aws_s3_bucket.results.id
  eventbridge = true
}

resource "aws_cloudwatch_event_rule" "record_published" {
  name        = "forge-perf-record-published"
  description = "A run record landed in published/<box>/ of the results bucket."
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [module.constants.results_bucket_name] }
      object = { key = [{ wildcard = "published/*/*-*.json" }] }
    }
  })
}

resource "aws_cloudwatch_event_connection" "github" {
  name               = "forge-perf-github-dispatch"
  description        = "GitHub token that dispatches publish.yml, set by hand."
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "Authorization"
      value = "Bearer set-by-operator"
    }

    invocation_http_parameters {
      header {
        key   = "Accept"
        value = "application/vnd.github+json"
      }
      header {
        key   = "X-GitHub-Api-Version"
        value = "2022-11-28"
      }
    }
  }

  # The operator's update-connection replaces the placeholder; an apply must
  # not put it back.
  lifecycle {
    ignore_changes = [auth_parameters]
  }
}

resource "aws_cloudwatch_event_api_destination" "publish_dispatch" {
  name                             = "forge-perf-publish-dispatch"
  description                      = "workflow_dispatch of publish.yml on main."
  invocation_endpoint              = "https://api.github.com/repos/fil-forge/forge-perf/actions/workflows/publish.yml/dispatches"
  http_method                      = "POST"
  invocation_rate_limit_per_second = 1
  connection_arn                   = aws_cloudwatch_event_connection.github.arn
}

data "aws_iam_policy_document" "publish_dispatch_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [module.constants.nonprod_account_id]
    }
  }
}

resource "aws_iam_role" "publish_dispatch" {
  name               = "forge-perf-publish-dispatch"
  assume_role_policy = data.aws_iam_policy_document.publish_dispatch_trust.json
}

data "aws_iam_policy_document" "publish_dispatch" {
  statement {
    actions   = ["events:InvokeApiDestination"]
    resources = [aws_cloudwatch_event_api_destination.publish_dispatch.arn]
  }
}

resource "aws_iam_role_policy" "publish_dispatch" {
  name   = "invoke-publish-dispatch"
  role   = aws_iam_role.publish_dispatch.id
  policy = data.aws_iam_policy_document.publish_dispatch.json
}

# publish.yml queues rather than cancels, so a burst of records ends in one or
# two publishes. A dispatch GitHub refuses, such as with an expired token, is
# retried for an hour and then dropped; the schedule catches up.
resource "aws_cloudwatch_event_target" "publish_dispatch" {
  rule     = aws_cloudwatch_event_rule.record_published.name
  arn      = aws_cloudwatch_event_api_destination.publish_dispatch.arn
  role_arn = aws_iam_role.publish_dispatch.arn
  input    = jsonencode({ ref = "main" })

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 20
  }
}

# ---------------------------------------------------------------------------
# Requests bucket.
#
# A /forge-perf comment on a service repository's pull request queues a request
# in requests/ through the request role; the persistent box takes it and
# answers in status/ (docs/runner.md, "Experiments"). Nothing here is a record:
# the runs publish like any other, so both prefixes expire after 30 days.

resource "aws_s3_bucket" "requests" {
  bucket = module.constants.requests_bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "requests" {
  bucket = aws_s3_bucket.requests.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "requests" {
  bucket                  = aws_s3_bucket.requests.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "requests" {
  bucket = aws_s3_bucket.requests.id

  dynamic "rule" {
    for_each = toset(["requests", "status"])

    content {
      id     = "expire-${rule.key}"
      status = "Enabled"

      filter {
        prefix = "${rule.key}/"
      }

      expiration {
        days = 30
      }

      abort_incomplete_multipart_upload {
        days_after_initiation = 1
      }
    }
  }
}

# ---------------------------------------------------------------------------
# The waker.
#
# With SLEEP_WHEN_IDLE=1 in config/launch.conf the persistent box powers
# itself off when it has nothing to do (docs/runner.md, "Sleeping"). This
# function runs every five minutes and starts the box again when its last
# heartbeat says asleep and there is a reason: its wake time has come, a
# /forge-perf request is waiting, or main's image set changed
# (scripts/waker/waker.py). It can start that one instance and nothing else,
# and it holds no GitHub credential: smelt's head and the image digests are
# public.
#
# The function's code is zipped from this checkout, so a change to
# scripts/waker/waker.py, config/images.tracked or config/smelt.conf reaches
# it at the next apply of this root.

locals {
  waker_name = "forge-perf-waker"
  waker_box  = "main"
  repo_root  = "${path.module}/../../../.."
}

data "archive_file" "waker" {
  type        = "zip"
  output_path = "${path.module}/.terraform/waker.zip"

  source {
    content  = file("${local.repo_root}/scripts/waker/waker.py")
    filename = "waker.py"
  }

  source {
    content  = file("${local.repo_root}/config/images.tracked")
    filename = "images.tracked"
  }

  source {
    content  = file("${local.repo_root}/config/smelt.conf")
    filename = "smelt.conf"
  }
}

data "aws_iam_policy_document" "waker_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "waker" {
  name               = local.waker_name
  assume_role_policy = data.aws_iam_policy_document.waker_trust.json
}

resource "aws_cloudwatch_log_group" "waker" {
  name              = "/aws/lambda/${local.waker_name}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "waker" {
  # DescribeInstances takes no resource or tag condition.
  statement {
    sid       = "FindTheBox"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "StartTheBox"
    actions   = ["ec2:StartInstances"]
    resources = ["arn:aws:ec2:${module.constants.region}:${module.constants.nonprod_account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["forge-perf"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Box"
      values   = [local.waker_box]
    }
  }

  statement {
    sid       = "ReadTheHeartbeat"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${module.constants.results_bucket_name}/published/${local.waker_box}/heartbeat.json"]
  }

  statement {
    sid       = "KeepItsRecord"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::${module.constants.results_bucket_name}/published/${local.waker_box}/waker.json"]
  }

  # With the listing allowed, a missing heartbeat or record reads as not
  # found, not as access denied.
  statement {
    sid       = "ListPublishedForTheBox"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${module.constants.results_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["published/${local.waker_box}/*"]
    }
  }

  statement {
    sid       = "SeeRequests"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${module.constants.requests_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["requests/*"]
    }
  }

  # The group's ARN written out, so the whole policy is known at plan time and
  # the tests can read it.
  statement {
    sid       = "WriteItsLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${module.constants.region}:${module.constants.nonprod_account_id}:log-group:/aws/lambda/${local.waker_name}:*"]
  }
}

resource "aws_iam_role_policy" "waker" {
  name   = "wake-the-box"
  role   = aws_iam_role.waker.id
  policy = data.aws_iam_policy_document.waker.json
}

resource "aws_lambda_function" "waker" {
  function_name    = local.waker_name
  description      = "Starts the sleeping persistent box when it has work."
  role             = aws_iam_role.waker.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "waker.handler"
  filename         = data.archive_file.waker.output_path
  source_code_hash = data.archive_file.waker.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      BOX             = local.waker_box
      RESULTS_BUCKET  = module.constants.results_bucket_name
      REQUESTS_BUCKET = module.constants.requests_bucket_name
    }
  }

  # The function would otherwise create its own log group, without retention.
  depends_on = [aws_cloudwatch_log_group.waker, aws_iam_role_policy.waker]
}

resource "aws_cloudwatch_event_rule" "waker" {
  name                = "forge-perf-waker-tick"
  description         = "Runs the waker every five minutes."
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "waker" {
  rule = aws_cloudwatch_event_rule.waker.name
  arn  = aws_lambda_function.waker.arn
}

resource "aws_lambda_permission" "waker" {
  statement_id  = "tick"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.waker.arn
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

# The source condition makes the key usable only through the forge-perf S3
# gateway endpoint, which only the forge-perf subnet's route table reaches.
# aws:SourceVpc would also admit infra-nodes' dev node, which shares the
# default VPC.
#
# The endpoint belongs to the network root, which CI applies with roles this
# root creates, so on a new account the first apply here comes before the
# endpoint exists. That apply sets piri_key_via_s3_endpoint = false and binds
# the key to the default VPC; the next apply, once the network root is up,
# binds it to the endpoint (docs/operations.md, "The network root").
variable "piri_key_via_s3_endpoint" {
  description = "Bind piri's key to the forge-perf S3 gateway endpoint (true) or to the default VPC (false, only before the network root exists)."
  type        = bool
  default     = true
}

data "aws_vpc_endpoint" "s3" {
  count = var.piri_key_via_s3_endpoint ? 1 : 0

  vpc_id       = data.aws_vpc.default.id
  service_name = "com.amazonaws.${module.constants.region}.s3"
  tags = {
    Name = module.constants.s3_endpoint_name
  }
}

locals {
  piri_source = (var.piri_key_via_s3_endpoint
    ? { key = "aws:SourceVpce", value = one(data.aws_vpc_endpoint.s3[*].id) }
    : { key = "aws:SourceVpc", value = data.aws_vpc.default.id }
  )
}

data "aws_iam_policy_document" "piri" {
  statement {
    sid       = "PiriBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = ["arn:aws:s3:::${module.constants.piri_bucket_name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = local.piri_source.key
      values   = [local.piri_source.value]
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
      variable = local.piri_source.key
      values   = [local.piri_source.value]
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

# Runs send almost nothing to the internet: S3 goes through the gateway
# endpoint and image pulls are ingress. A tracked image that streams out at the
# NIC's rate for a whole run would cost hundreds of dollars an hour, so egress
# gets its own small budget rather than waiting on the monthly total.
resource "aws_budgets_budget" "internet_egress" {
  name         = "forge-perf-internet-egress"
  budget_type  = "COST"
  limit_amount = "25"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$forge-perf"]
  }

  cost_filter {
    name   = "UsageTypeGroup"
    values = ["EC2: Data Transfer - Internet (Out)"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget.arn]
  }

  depends_on = [aws_sns_topic_policy.budget]
}
