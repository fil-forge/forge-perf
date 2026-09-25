# What `tofu apply` and `tofu destroy` need for the network and box roots.
#
# No IAM user actions, no ssm:*, no kms:* and no access to the results bucket:
# the piri user, its key, the SSM parameters and the results bucket belong to
# the bootstrap root, which an operator applies.
data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "ManageBoxInfrastructure"
    actions   = ["ec2:*", "sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # The account also holds infra-nodes' dev node and infra-central's dev stage,
  # and any workflow on main of a public repository can assume this role. It
  # may not stop, modify or delete what it did not create. A negated condition
  # also matches when the tag is absent, so untagged resources are protected
  # too. Every forge-perf resource carries the tag through default_tags.
  statement {
    sid       = "KeepOffOtherProjects"
    effect    = "Deny"
    resources = ["*"]

    actions = [
      "ec2:DeleteRoute",
      "ec2:DeleteRouteTable",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSubnet",
      "ec2:DeleteVolume",
      "ec2:DeleteVpcEndpoints",
      "ec2:ModifyInstanceAttribute",
      "ec2:ReplaceRoute",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/${var.tag_key}"
      values   = [var.tag_value]
    }
  }

  # Without this the deny above is one call away from useless: tag a dev
  # resource Project=forge-perf, then stop it. Tagging at creation carries
  # ec2:CreateAction and stays allowed; retagging an existing resource that is
  # not already forge-perf's is denied.
  statement {
    sid       = "NoRetaggingIntoScope"
    effect    = "Deny"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/${var.tag_key}"
      values   = [var.tag_value]
    }

    condition {
      test     = "Null"
      variable = "ec2:CreateAction"
      values   = ["true"]
    }
  }

  statement {
    sid       = "ReadRoles"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # IAM writes stay on the box roles. A role that could write any role could
  # grant itself anything; the CI roles are outside this pattern, so this role
  # cannot rewrite its own trust policy.
  statement {
    sid = "WriteBoxRoles"

    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:CreateRole",
      "iam:DeleteInstanceProfile",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]

    resources = [
      "arn:aws:iam::${var.account_id}:role/${var.name_prefix}-box-*",
      "arn:aws:iam::${var.account_id}:instance-profile/${var.name_prefix}-box-*",
    ]
  }

  statement {
    sid       = "PassBoxRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/${var.name_prefix}-box-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Objects too, on purpose: destroying a campaign box empties its buckets.
  statement {
    sid       = "ManagePiriBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${var.piri_bucket_name_prefix}-*"]
  }

  statement {
    sid       = "ReadWriteState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for p in var.state_key_prefixes : "${local.state_bucket_arn}/${p}/*"]
  }

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }
}
