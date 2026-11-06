output "active_model" {
  description = "Completed release consumed by vLLM; publishing is gated on object uploads"
  value = {
    account_id      = data.aws_caller_identity.current.account_id
    bucket          = aws_s3_bucket.models.id
    bucket_arn      = aws_s3_bucket.models.arn
    prefix          = local.prefixes[var.active_release]
    model_id        = var.releases[var.active_release].model_id
    revision        = var.releases[var.active_release].revision
    manifest_sha256 = local.manifest_hashes[var.active_release]
    s3_endpoint_id  = data.terraform_remote_state.vpc.outputs.s3_endpoint_id
    region          = var.region
    cluster_name    = var.cluster_name
  }
  depends_on = [aws_s3_object.manifest]
}
