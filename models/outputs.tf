output "bucket_name" {
  description = "Pass this bucket to the explicit model publisher"
  value       = aws_s3_bucket.models.id
}
