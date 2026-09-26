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
  # may not stop, modify, delete, detach or copy what it did not create. A
  # negated condition also matches when the tag is absent, so untagged
  # resources are protected too. Every forge-perf resource carries the tag
  # through default_tags. The create actions left out (CreateSubnet,
  # CreateSecurityGroup, CreateVpcEndpoint, RunInstances) authorize against the
  # untagged default VPC or a Canonical AMI, so they cannot sit under this
  # condition. Whether every family below spares the network and box roots'
  # own calls is [unverified] until their first apply.
  statement {
    sid       = "KeepOffOtherProjects"
    effect    = "Deny"
    resources = ["*"]
    actions   = local.untagged_denied_actions

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/${var.tag_key}"
      values   = [var.tag_value]
    }
  }

  # A new rule carries no tags, so rule changes are judged by the security
  # group they belong to alone.
  statement {
    sid    = "KeepOffOtherSecurityGroups"
    effect = "Deny"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:ModifySecurityGroupRules",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
    ]
    resources = ["arn:aws:ec2:*:*:security-group/*"]

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

  # IAM writes stay on the box roles, and every box role carries the box
  # permissions boundary. The name prefix alone would not contain this role: it
  # could create forge-perf-box-x with an administrator policy and launch an
  # instance with it. The boundary caps any box role at what a box needs, and
  # the CI roles are outside the pattern, so this role cannot rewrite its own
  # trust policy either.
  statement {
    sid = "WriteBoxRolesWithinBoundary"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
    ]
    resources = [local.box_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.box_boundary_arn]
    }
  }

  # Session Manager's managed policy is the only one a box role may attach.
  statement {
    sid       = "AttachSessionManagerPolicy"
    actions   = ["iam:AttachRolePolicy"]
    resources = [local.box_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.box_boundary_arn]
    }

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
    }
  }

  # None of these can widen what a box role may do, which the boundary caps.
  statement {
    sid = "ManageBoxRoles"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:DeleteRole",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:TagRole",
      "iam:UntagInstanceProfile",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = [local.box_role_arn, local.box_profile_arn]
  }

  statement {
    sid    = "KeepTheBoundary"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutRolePermissionsBoundary",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassBoxRole"
    actions   = ["iam:PassRole"]
    resources = [local.box_role_arn]

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
