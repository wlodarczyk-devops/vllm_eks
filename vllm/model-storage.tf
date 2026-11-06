data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_s3_bucket" "models" {
  bucket = "${var.cluster_name}-models-${data.aws_caller_identity.current.account_id}-${var.region}"
}

data "aws_vpc_endpoint" "s3" {
  vpc_id       = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  service_name = "com.amazonaws.${var.region}.s3"
}

locals {
  model_release       = jsondecode(file("${path.module}/../models/release.json"))
  cluster_oidc_issuer = trimprefix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
  cluster_oidc_arn    = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.cluster_oidc_issuer}"
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
      values   = ["system:serviceaccount:${var.namespace}:vllm"]
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
  assume_role_policy = data.aws_iam_policy_document.model_reader_trust.json
}

data "aws_iam_policy_document" "model_reader" {
  statement {
    sid = "ReadSelectedModelVersionThroughEndpoint"
    # One exact versioned archive needs neither bucket listing nor object writes.
    actions   = ["s3:GetObjectVersion"]
    resources = ["${data.aws_s3_bucket.models.arn}/${local.model_release.key}"]
    condition {
      test     = "StringEquals"
      variable = "s3:VersionId"
      values   = [coalesce(local.model_release.version_id, "UNPUBLISHED")]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [data.aws_vpc_endpoint.s3.id]
    }
  }
}

resource "aws_iam_role_policy" "model_reader" {
  name   = "read-selected-model-version"
  role   = aws_iam_role.model_reader.id
  policy = data.aws_iam_policy_document.model_reader.json
}
