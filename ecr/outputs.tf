output "repository_url" {
  description = "Push engine and downloader images here before deploying vLLM"
  value       = aws_ecr_repository.vllm.repository_url
}

output "repository_name" {
  value = aws_ecr_repository.vllm.name
}
