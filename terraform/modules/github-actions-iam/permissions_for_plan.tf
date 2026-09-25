# What `tofu plan` needs for the network and box roots, and nothing more.
#
# infra-central's plan policy cut down to the services this tree uses. A
# refresh describes each resource and never reads what it holds, so there is no
# s3:GetObject outside state, no ssm:* and no kms:*: a pull request chooses the
# commands this role runs.
data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "DescribeInfrastructure"
    resources = ["*"]

    actions = [
      "ec2:Describe*",
      "iam:Get*",
      "iam:List*",
      # GetBucket* misses the accelerate and replication reads a bucket refresh
      # makes. All of these read configuration, never an object.
      "s3:GetAccelerateConfiguration",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
      "sts:GetCallerIdentity",
    ]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = [for p in var.state_key_prefixes : "${local.state_bucket_arn}/${p}/*.tfstate"]
  }

  # use_lockfile keeps the lock in its own <key>.tflock object, so the plan
  # role can take a lock without being able to overwrite the state it locks.
  statement {
    sid       = "HoldStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for p in var.state_key_prefixes : "${local.state_bucket_arn}/${p}/*.tflock"]
  }

  # Unprefixed, because `tofu init` lists the bucket before it knows its key.
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }
}
