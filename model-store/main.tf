data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "terraform_remote_state" "vpc" {
  backend = "local"
  config  = { path = var.vpc_state_path }
}

locals {
  manifests = {
    for name, release in var.releases : name => jsondecode(file("${path.module}/${release.directory}/manifest.json"))
  }
  manifest_hashes = {
    for name, release in var.releases : name => filesha256("${path.module}/${release.directory}/manifest.json")
  }
  prefixes = {
    for name, release in var.releases : name => "models/${release.model_id}/${release.revision}/${local.manifest_hashes[name]}"
  }
  files = merge([
    for name, manifest in local.manifests : {
      for file in manifest.files : "${name}/${file.path}" => merge(file, {
        release = name
        source  = "${path.module}/${var.releases[name].directory}/files/${file.path}"
      })
    }
  ]...)
  reader_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-vllm-model-reader"
}

resource "aws_s3_bucket" "models" {
  bucket        = "${var.cluster_name}-models-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = false
  tags          = var.tags
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "models" {
  bucket = aws_s3_bucket.models.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration { status = "Enabled" }
}

# SSE-S3 is sufficient for these public upstream weights and avoids granting
# runtime KMS permissions. Use SSE-KMS if your organization's key policy needs it.
resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.models.arn, "${aws_s3_bucket.models.arn}/*"]
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
  # Restrict the runtime role without locking out the external Terraform publisher.
  # The role may not exist yet: a PrincipalArn condition avoids an invalid principal.
  statement {
    sid       = "DenyModelReaderOutsideEndpoint"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
    resources = [aws_s3_bucket.models.arn, "${aws_s3_bucket.models.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.reader_role_arn]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = [data.terraform_remote_state.vpc.outputs.s3_endpoint_id]
    }
  }
}

resource "aws_s3_bucket_policy" "models" {
  bucket     = aws_s3_bucket.models.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.models]
}

# Stream files from disk. No weights are embedded in Terraform configuration/state,
# and no local-exec provisioner installs tools or performs hidden network transfers.
resource "aws_s3_object" "files" {
  for_each = local.files

  bucket                 = aws_s3_bucket.models.id
  key                    = "${local.prefixes[each.value.release]}/files/${each.value.path}"
  source                 = each.value.source
  source_hash            = each.value.sha256
  checksum_algorithm     = "SHA256"
  server_side_encryption = "AES256"
  tags                   = var.tags

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", each.value.path)) && !contains(split("/", each.value.path), "..")
      error_message = "Manifest paths must be safe relative paths."
    }
    precondition {
      condition     = filesha256(each.value.source) == each.value.sha256
      error_message = "Local model bytes differ from the release manifest; prepare a new release."
    }
  }
  depends_on = [
    aws_s3_bucket_versioning.models,
    aws_s3_bucket_server_side_encryption_configuration.models,
    aws_s3_bucket_ownership_controls.models,
    aws_s3_bucket_policy.models,
  ]
}

# Publish the completion manifest only after all model objects are uploaded.
resource "aws_s3_object" "manifest" {
  for_each = var.releases

  bucket                 = aws_s3_bucket.models.id
  key                    = "${local.prefixes[each.key]}/manifest.json"
  source                 = "${path.module}/${each.value.directory}/manifest.json"
  source_hash            = local.manifest_hashes[each.key]
  checksum_algorithm     = "SHA256"
  server_side_encryption = "AES256"
  content_type           = "application/json"
  tags                   = var.tags

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = local.manifests[each.key].schema_version == 1 && local.manifests[each.key].model_id == each.value.model_id && local.manifests[each.key].revision == each.value.revision && length(local.manifests[each.key].files) > 0
      error_message = "Manifest identity must match the declared release and include model files."
    }
  }
  depends_on = [aws_s3_object.files]
}
