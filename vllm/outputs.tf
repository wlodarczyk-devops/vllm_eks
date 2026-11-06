output "port_forward" {
  description = "Command to reach the vLLM API on localhost (same port as var.port)"
  value       = "kubectl -n ${var.namespace} port-forward svc/${kubernetes_service_v1.vllm.metadata[0].name} ${var.port}:${var.port}"
}

output "test_request" {
  description = "Example chat completion request (run after port_forward)"
  value       = "curl -s localhost:${var.port}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${local.model_release.model_id}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
}
