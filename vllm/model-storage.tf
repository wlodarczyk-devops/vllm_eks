variable "model_store_state_path" {
  description = "State of the model-store stack after its active release has been uploaded"
  type        = string
  default     = "../model-store/terraform.tfstate"
}

variable "model_downloader_image" {
  description = "AWS CLI 2.39.3 image, resolved to a multi-architecture digest on 2026-11-06"
  type        = string
  default     = "amazon/aws-cli@sha256:d557b3524475d70dd3104cf44d96568ee3188897b73a6ece2b37aa50e1af362f"
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.model_downloader_image))
    error_message = "Pin the model downloader image to a complete sha256 digest."
  }
}

data "terraform_remote_state" "model_store" {
  backend = "local"
  config  = { path = var.model_store_state_path }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  stored_model         = data.terraform_remote_state.model_store.outputs.active_model
  model_reader_account = "vllm-model-reader"
  cluster_oidc_issuer  = trimprefix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
  cluster_oidc_arn     = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.cluster_oidc_issuer}"
}

data "aws_iam_policy_document" "model_reader_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.cluster_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.cluster_oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${local.model_reader_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.cluster_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "model_reader" {
  name               = "${var.cluster_name}-vllm-model-reader"
  description        = "Read the selected vLLM model release through the S3 gateway endpoint"
  assume_role_policy = data.aws_iam_policy_document.model_reader_trust.json
}

data "aws_iam_policy_document" "model_reader" {
  statement {
    sid       = "ReadSelectedModel"
    actions   = ["s3:GetObject"]
    resources = ["${local.stored_model.bucket_arn}/${local.stored_model.prefix}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [local.stored_model.s3_endpoint_id]
    }
  }
  statement {
    sid       = "ListSelectedModelFiles"
    actions   = ["s3:ListBucket"]
    resources = [local.stored_model.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.stored_model.prefix}/files", "${local.stored_model.prefix}/files/*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [local.stored_model.s3_endpoint_id]
    }
  }
}

resource "aws_iam_role_policy" "model_reader" {
  name   = "read-selected-model"
  role   = aws_iam_role.model_reader.id
  policy = data.aws_iam_policy_document.model_reader.json
}

resource "kubernetes_service_account_v1" "model_reader" {
  metadata {
    name      = local.model_reader_account
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  automount_service_account_token = false
  # No role annotation: explicit STS projection below restricts token/env mounts
  # to the downloader. The webhook would otherwise inject them into every container.
}

resource "kubernetes_config_map_v1" "model_verifier" {
  metadata {
    name      = "vllm-model-verifier"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  data = { "manifest.py" = file("${path.module}/../model-store/manifest.py") }
}
