output "bucket" {
  value = aws_s3_bucket.site.id
}

output "distribution_id" {
  value = aws_cloudfront_distribution.site.id
}

output "distribution_domain" {
  value = aws_cloudfront_distribution.site.domain_name
}

output "deployer_role_arn" {
  value = aws_iam_role.deployer.arn
}
