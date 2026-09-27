# The bucket every root module in this account keeps its state in.
#
# One per account rather than one per node: state files are small, they are
# namespaced by key, and a second bucket would need its own creation and its own
# policy for nothing. The account id in the name makes it globally unique and
# names, in the one place an operator reads before running anything, which
# account the state describes.
#
# This bucket is what the `backend "s3"` blocks point at, which makes it the one
# resource that cannot be created by the apply that consumes it. See the
# bootstrap procedure in the runbook: the first apply in a new account runs
# against a local backend, then moves its own state in here.
#
# Adapted from infra-central's module of the same name. The two repositories
# deploy into the same account and share every OpenTofu convention, so a
# difference here would be a difference to explain.

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  # Deleting this bucket loses every node's state in the account, and OpenTofu
  # cannot rebuild a node from nothing. force_destroy is left at its default for
  # the same reason: an accidental destroy should fail on a non-empty bucket
  # rather than succeed.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = var.bucket_name }
}

# A state file is not reproducible from anything else, and the failure this
# protects against is real: a half-written state, or an operator pushing the
# wrong file, is recoverable only from a previous version.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Versioning without an expiry rule accumulates every state an apply has ever
# written, forever. Ninety days is long enough that a mistake noticed late is
# still recoverable and short enough that the bucket does not grow without
# bound.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # The noncurrent-version rule is only valid once versioning is enabled.
  # Without this ordering the two requests race on the first apply.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Abandoned parts from an upload that died partway through are invisible
    # in listings but still billed; this cleans them up. It does not expire
    # stale locks: a lock left by a killed run is a completed object that only
    # `tofu force-unlock` (or deleting the object by hand) removes.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# SSE-S3 (`AES256`): server-side encryption under a key S3 owns and manages, with
# no key resource, key policy or rotation for this project to run.
#
# The alternative, SSE-KMS under a customer-managed key, buys an access boundary
# and a decrypt audit trail. Neither is worth its cost here. A node's state file
# holds instance ids, volume ids, an Elastic IP and DNS names; every secret the
# node has lives in the OpenBao on the node itself and none of it passes through
# OpenTofu, so there is nothing in these objects a second layer of access
# control would protect.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
