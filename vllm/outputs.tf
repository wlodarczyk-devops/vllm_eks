output "port_forward" {
  description = "Command to reach the vLLM API on localhost:8000"
  value       = "kubectl -n ${var.namespace} port-forward svc/${kubernetes_service_v1.vllm.metadata[0].name} 8000:8000"
}

output "test_request" {
  description = "Example chat completion request (run after port_forward)"
  value       = "curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${var.model}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
}
