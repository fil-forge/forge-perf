# The permissions boundary every box instance role carries.
#
# The apply role may create box roles, and an instance runs with whatever its
# role allows, so a box role's reach is the apply role's reach. The boundary
# caps it at what DESIGN.md gives a box: Session Manager, the /forge-perf
# parameters, write-only access to the results bucket and emptying its piri
# buckets. The box roots set it as permissions_boundary; the apply role cannot
# create or change a box role without it, nor edit or remove it.

locals {
  box_role_arn     = "arn:aws:iam::${var.account_id}:role/${var.name_prefix}-box-*"
  box_profile_arn  = "arn:aws:iam::${var.account_id}:instance-profile/${var.name_prefix}-box-*"
  box_boundary_arn = "arn:aws:iam::${var.account_id}:policy/${var.name_prefix}-box-boundary"

  # The only actions KeepOffOtherProjects lets through on a resource lacking the
  # project tag. Everything else is denied there, so a new EC2 action is denied
  # on other projects' resources until it is named here.
  untagged_allowed_actions = [
    "ec2:Describe*",
    # Creates that authorize against the untagged default VPC, a Canonical AMI or
    # the resource being created. LaunchIntoOwnNetworkOnly keeps the subnet,
    # security group and route table they use forge-perf's own.
    "ec2:CreateRouteTable",
    "ec2:CreateSecurityGroup",
    "ec2:CreateSubnet",
    "ec2:CreateVpcEndpoint",
    "ec2:RunInstances",
    # Judged by KeepOffOtherSecurityGroups and NoRetaggingIntoScope.
    "ec2:AuthorizeSecurityGroupEgress",
    "ec2:AuthorizeSecurityGroupIngress",
    "ec2:CreateTags",
    # EBS encrypting a box volume under the untagged AWS-managed aws/ebs key,
    # with the caller's identity. KmsThroughEc2Only keeps them on that path.
    "kms:CreateGrant",
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
    # Scoped by resource in their own statements.
    "iam:*",
    "s3:*",
    "sts:*",
  ]
}

data "aws_iam_policy_document" "box_boundary" {
  # The actions of AmazonSSMManagedInstanceCore other than parameter reads.
  statement {
    sid = "SessionManager"
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
      "ssm:DescribeAssociation",
      "ssm:DescribeDocument",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:GetManifest",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:PutInventory",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${var.account_id}:parameter${var.ssm_path}/*"]
  }

  statement {
    sid       = "DecryptParameters"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }

  # The persistent box takes /forge-perf requests from the queue and answers
  # in status/. It cannot write a request or read the results role's data.
  statement {
    sid       = "ListRequests"
    actions   = ["s3:ListBucket"]
    resources = [local.requests_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["requests/*"]
    }
  }

  statement {
    sid       = "TakeRequests"
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${local.requests_bucket_arn}/requests/*"]
  }

  statement {
    sid       = "AnswerRequests"
    actions   = ["s3:PutObject"]
    resources = ["${local.requests_bucket_arn}/status/*"]
  }

  statement {
    sid       = "WriteResults"
    actions   = ["s3:AbortMultipartUpload", "s3:PutObject"]
    resources = ["${local.results_bucket_arn}/raw/*", "${local.results_bucket_arn}/published/*"]
  }

  statement {
    sid = "EmptyPiriBuckets"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [
      "arn:aws:s3:::${var.piri_bucket_name_prefix}-*",
      "arn:aws:s3:::${var.piri_bucket_name_prefix}-*/*",
    ]
  }
}

resource "aws_iam_policy" "box_boundary" {
  name        = "${var.name_prefix}-box-boundary"
  description = "Permissions boundary of every ${var.name_prefix} box instance role."
  policy      = data.aws_iam_policy_document.box_boundary.json
}
