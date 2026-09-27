output "bucket_name" {
  description = "The name to put in a node root's backend block."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}
