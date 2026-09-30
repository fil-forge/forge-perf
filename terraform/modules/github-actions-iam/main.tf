# The three roles GitHub Actions assumes in this repository.
#
# Adapted from infra-central's module of the same name. Plan and apply are split
# the same way: GitHub runs a `pull_request` workflow from the pull request's
# own head, so the plan role can describe infrastructure and read nothing, and
# the role that changes anything is reachable only from main. The third role
# reads published run records for the page and nothing else.
#
# No access key is stored anywhere. A run exchanges its GitHub OIDC token for
# credentials that expire with it.

# Read, never create. The account has one GitHub OIDC provider, shared with
# every other repository that deploys into it; owning it here would let a
# destroy of this root break them.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # GitHub mints the repository part of the `sub` claim in one of two shapes:
  # `repo:<owner>/<repo>` or, for a repository created after 2026-07-15 like
  # this one, `repo:<owner>@<owner_id>/<repo>@<repo_id>`. Each role accepts
  # both, matched exactly, so a move between shapes does not lock CI out and a
  # wildcard never makes two roles interchangeable.
  shapes = ["repo:${var.repository}", var.repository_subject_prefix]

  plan_subjects = [for s in local.shapes : "${s}:pull_request"]
  main_subjects = [for s in local.shapes : "${s}:ref:refs/heads/main"]

  # A job that names a GitHub environment gets the environment in its `sub` in
  # place of the ref. The box roots apply in an environment with a required
  # reviewer and main as its only deployment branch, so the apply role trusts
  # that subject too.
  environment_subjects = flatten([
    for e in var.apply_environments : [for s in local.shapes : "${s}:environment:${e}"]
  ])

  state_bucket_arn    = "arn:aws:s3:::${var.state_bucket_name}"
  results_bucket_arn  = "arn:aws:s3:::${var.results_bucket_name}"
  requests_bucket_arn = "arn:aws:s3:::${var.requests_bucket_name}"
}

data "aws_iam_policy_document" "assume" {
  for_each = {
    plan    = local.plan_subjects
    apply   = concat(local.main_subjects, local.environment_subjects)
    results = local.main_subjects
    request = var.request_subjects
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

locals {
  roles = {
    plan = {
      description = "GitHub Actions: tofu plan on pull requests. Describes infrastructure, reads no data."
      policy      = data.aws_iam_policy_document.plan.json
    }
    apply = {
      description = "GitHub Actions: tofu apply on main, campaign boxes and the reaper."
      policy      = data.aws_iam_policy_document.apply.json
    }
    results = {
      description = "GitHub Actions: reads published run records from the results bucket."
      policy      = data.aws_iam_policy_document.results.json
    }
    request = {
      description = "GitHub Actions in the service repositories: queues a /forge-perf request and reads the box's answer."
      policy      = data.aws_iam_policy_document.request.json
    }
  }
}

resource "aws_iam_role" "this" {
  for_each           = local.roles
  name               = "${var.name_prefix}-ci-${each.key}"
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
}

resource "aws_iam_role_policy" "this" {
  for_each = local.roles
  name     = each.key
  role     = aws_iam_role.this[each.key].id
  policy   = each.value.policy
}

# The results role lists and reads published/ and nothing else, so a mistake in
# the publishing workflow cannot pull raw run text into the public repository.
# The bucket policy in the bootstrap root adds an explicit deny on raw/.
data "aws_iam_policy_document" "results" {
  statement {
    sid       = "ListPublished"
    actions   = ["s3:ListBucket"]
    resources = [local.results_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["published/*"]
    }
  }

  statement {
    sid       = "ReadPublished"
    actions   = ["s3:GetObject"]
    resources = ["${local.results_bucket_arn}/published/*"]
  }
}


# The request role is the service repositories' only way in. It adds a request
# to the queue and reads the box's answer; it cannot read another request, list
# the bucket, delete anything or touch the results bucket. The box validates
# every request it takes (docs/runner.md, "Experiments").
data "aws_iam_policy_document" "request" {
  statement {
    sid       = "QueueRequests"
    actions   = ["s3:PutObject"]
    resources = ["${local.requests_bucket_arn}/requests/*"]
  }

  statement {
    sid       = "ReadStatus"
    actions   = ["s3:GetObject"]
    resources = ["${local.requests_bucket_arn}/status/*"]
  }
}
