output "repository_url" {
  description = "Push the combined vLLM/model image here before deploying vLLM"
  value       = aws_ecr_repository.vllm.repository_url
}

output "repository_name" {
  value = aws_ecr_repository.vllm.name
}
