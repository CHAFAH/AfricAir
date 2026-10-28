# Project 1, Part C: private S3 bucket behind CloudFront (Origin Access Control), security headers,
# and a deployer role that can only publish to this bucket and invalidate this distribution.

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "site" {
  bucket        = var.bucket_name
  force_destroy = true # a static build is reproducible from Git
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id
  versioning_configuration { status = "Enabled" } # deleted or overwritten files stay recoverable
}

# SSE-S3 as the spec requires: the bucket holds the public site, and OAC reads SSE-S3 objects without KMS grants.
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" } # SSE-S3 (OAC can read it without KMS grants)
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = var.bucket_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${var.name}-security-headers"
  security_headers_config {
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_security_policy {
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
      override                = true
    }
  }
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized" # honours the Cache-Control set by publish-s3.sh
}

# No WAF: a static, read-only site (GET/HEAD only) in a bootcamp account; WAF costs $5+/month plus rules.
# Add aws_wafv2_web_acl with the AWS managed common rule set for anything real.
#trivy:ignore:AVD-AWS-0011
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = "${var.name} static site"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"
  is_ipv6_enabled     = true

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # *.cloudfront.net; use an ACM certificate (us-east-1) for a custom domain
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  tags = var.tags
}

# Only this distribution (through OAC) may read the bucket.
data "aws_iam_policy_document" "site" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
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

resource "aws_s3_bucket_policy" "site" {
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.site.json
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# --- deployer: exactly deploy/iam/deployer-policy.json, rendered for this bucket and distribution ---
data "aws_iam_policy_document" "deployer_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.deployer_trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "deployer" {
  name               = "${var.name}-static-deployer"
  assume_role_policy = data.aws_iam_policy_document.deployer_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "deployer" {
  role = aws_iam_role.deployer.id
  policy = templatefile(var.deployer_policy_template, {
    bucket_name     = aws_s3_bucket.site.id
    account_id      = data.aws_caller_identity.current.account_id
    distribution_id = aws_cloudfront_distribution.site.id
  })
}
