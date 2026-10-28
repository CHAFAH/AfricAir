# One-time bootstrap: the S3 bucket that holds every other root module's state.
# Run with local state, once per account:  terraform -chdir=infra/terraform/bootstrap init && apply
# State locking uses S3 native lock files (use_lockfile = true), so no DynamoDB table is needed.

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = "africair", ManagedBy = "terraform", Component = "tf-state" } }
}

data "aws_caller_identity" "current" {}

locals {
  bucket = coalesce(var.bucket_name, "africair-tfstate-${data.aws_caller_identity.current.account_id}")
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket
  # State is the record of every resource: never destroy it by accident.
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" } # every state write is recoverable
}

# SSE-KMS with the AWS-managed key: a customer-managed key for the bootstrap bucket adds a lock-out risk
# (state unreadable if the key policy breaks) for little gain in a single-account setup.
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

data "aws_iam_policy_document" "tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.tls_only.json
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "bucket_name" {
  description = "Override the default africair-tfstate-<account-id>."
  type        = string
  default     = null
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}
