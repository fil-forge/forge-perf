# What `tofu apply` and `tofu destroy` need for the network and box roots.
#
# No IAM user actions, no ssm:*, no KMS grant and no access to the results
# bucket: the piri user, its key, the SSM parameters and the results bucket
# belong to the bootstrap root, which an operator applies.
data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "ManageBoxInfrastructure"
    actions   = ["ec2:*", "sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # The account also holds infra-nodes' dev node and infra-central's dev stage,
  # and any workflow on main of a public repository can assume this role. On a
  # resource lacking Project=forge-perf it may only describe, create in the
  # default VPC, and tag at creation: every other action is denied there,
  # including actions AWS adds later. A negated condition also matches when the
  # tag is absent, so untagged resources are protected too. Every resource
  # OpenTofu creates carries the tag through default_tags; a box root tags its
  # root volume at creation, and a security group change on the box accepts
  # replacement, since the primary network interface is created by RunInstances
  # untagged. The box's root volume is encrypted under the AWS-managed aws/ebs
  # key, which carries no tags, and EBS calls KMS for it as this role, so the
  # KMS calls EBS makes are allowlisted and KmsThroughEc2Only confines them.
  # Whether the network and box roots need any other action on an AWS-owned
  # resource (for example a managed prefix list read) is [unverified] until
  # their first apply; such an action joins untagged_allowed_actions.
  statement {
    sid         = "KeepOffOtherProjects"
    effect      = "Deny"
    resources   = ["*"]
    not_actions = local.untagged_allowed_actions

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/${var.tag_key}"
      values   = [var.tag_value]
    }
  }

  # The creates above authorize against a subnet, security group or route table
  # too. They must be forge-perf's, so the role cannot launch into the dev
  # node's subnet or add an endpoint route to another project's route table.
  statement {
    sid     = "LaunchIntoOwnNetworkOnly"
    effect  = "Deny"
    actions = ["ec2:CreateVpcEndpoint", "ec2:RunInstances"]
    resources = [
      "arn:aws:ec2:*:*:route-table/*",
      "arn:aws:ec2:*:*:security-group/*",
      "arn:aws:ec2:*:*:subnet/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/${var.tag_key}"
      values   = [var.tag_value]
    }
  }

  # The reaper, the budget and this role's own terminate rights all find an
  # instance by Project=forge-perf, so an instance must carry the tag from
  # launch. The type is limited to the box family, which caps what one launch
  # can cost.
  statement {
    sid       = "LaunchTaggedOnly"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/${var.tag_key}"
      values   = [var.tag_value]
    }
  }

  statement {
    sid       = "LaunchBoxTypesOnly"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotLike"
      variable = "ec2:InstanceType"
      values   = var.box_instance_types
    }
  }

  # Only gateway endpoints, which name no subnet or security group. An interface
  # endpoint with private DNS would redirect the whole default VPC's calls to
  # that service, the dev node's included.
  statement {
    sid     = "GatewayEndpointsOnly"
    effect  = "Deny"
    actions = ["ec2:CreateVpcEndpoint"]
    resources = [
      "arn:aws:ec2:*:*:security-group/*",
      "arn:aws:ec2:*:*:subnet/*",
    ]
  }

  # Boxes boot from Canonical's images, so the role cannot launch another
  # project's private AMI or a volume from its snapshot. Whether RunInstances
  # also evaluates the AMI's own backing snapshot, which Canonical owns, is
  # [unverified] until the first box apply.
  statement {
    sid     = "LaunchCanonicalImagesOnly"
    effect  = "Deny"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:aws:ec2:*::image/*",
      "arn:aws:ec2:*::snapshot/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "ec2:Owner"
      values   = [var.image_owner]
    }
  }

  # EBS uses aws/ebs with this role's identity. The role holds no KMS grant of
  # its own; this keeps whatever key-policy access it inherits on the EC2 path.
  statement {
    sid       = "KmsThroughEc2Only"
    effect    = "Deny"
    actions   = ["kms:*"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.region}.amazonaws.com"]
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
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
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
  # Trust-policy and role updates, and deletes, sit in the statement above, so a
  # box-named role made by hand without the boundary is out of reach.
  statement {
    sid = "ManageBoxRoles"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:TagRole",
      "iam:UntagInstanceProfile",
      "iam:UntagRole",
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
