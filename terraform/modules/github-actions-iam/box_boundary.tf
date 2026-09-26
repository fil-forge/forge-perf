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

  # What KeepOffOtherProjects denies on anything lacking the project tag: every
  # family that acts on an existing resource, plus the create actions that copy
  # or reroute one.
  untagged_denied_actions = [
    "ec2:AssociateAddress",
    "ec2:AssociateIamInstanceProfile",
    "ec2:Attach*",
    "ec2:CreateImage",
    "ec2:CreateInstanceExportTask",
    "ec2:CreateReplaceRootVolumeTask",
    "ec2:CreateRoute",
    "ec2:CreateSnapshot",
    "ec2:CreateSnapshots",
    "ec2:Delete*",
    "ec2:Detach*",
    "ec2:Disassociate*",
    "ec2:Modify*",
    "ec2:Reboot*",
    "ec2:Replace*",
    "ec2:Revoke*",
    "ec2:SendDiagnosticInterrupt",
    "ec2:Stop*",
    "ec2:Terminate*",
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
