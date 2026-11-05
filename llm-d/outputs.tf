output "port_forward" {
  description = "Command to reach the llm-d Router (Envoy) on localhost:8080"
  value       = "kubectl -n ${var.namespace} port-forward svc/${var.release_name}-epp 8080:80"
}

output "test_request" {
  description = "Example chat completion request through the llm-d Router (run after port_forward)"
  value       = "curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"Qwen/Qwen3-4B-Instruct-2507\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
}
