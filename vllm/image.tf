locals {
  image_release = jsondecode(file("${path.module}/../ecr/image/release.json"))
}

# Publish the image before planning this stack. Resolve the immutable release tag
# once, then deploy by digest so replacement pods use exactly the same artifact.
data "aws_ecr_repository" "vllm" {
  name = "${var.cluster_name}-vllm"
}

data "aws_ecr_image" "vllm" {
  repository_name = data.aws_ecr_repository.vllm.name
  image_tag       = local.image_release.image_tag
}

resource "kubernetes_service_account_v1" "vllm" {
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  automount_service_account_token = false
  # No role annotation: mount the explicit STS token only in the download init
  # container, rather than letting the webhook inject it into every container.
}

data "aws_ecr_image" "downloader" {
  repository_name = data.aws_ecr_repository.vllm.name
  image_tag       = local.image_release.downloader_tag
}
