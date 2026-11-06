resource "aws_ecr_repository" "vllm" {
  name                 = "${var.cluster_name}-vllm"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Preserve tagged releases for rollback. Only untagged build artifacts expire.
resource "aws_ecr_lifecycle_policy" "vllm" {
  repository = aws_ecr_repository.vllm.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
