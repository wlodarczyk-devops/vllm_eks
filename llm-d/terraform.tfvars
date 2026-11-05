region       = "eu-central-1"
cluster_name = "vllm-eks"

# Same namespace, labels and port as the vLLM Deployment in ../vllm
namespace           = "vllm"
model_server_labels = { app = "vllm" }
model_server_port   = 8000

release_name         = "llm-d"
router_chart_version = "v1.0.0"
# GAIE version used by llm-d v1.0.0 (guides/env.sh)
gaie_version = "v1.6.2"

# Router runs on the t3.medium system node (2 vCPU, 4 GiB; ~1.5 CPU free).
# llm-d recommends 4 CPU / 8 GiB each for production traffic.
epp_cpu_request    = "500m"
epp_memory_request = "512Mi"
epp_memory_limit   = "1Gi"

proxy_cpu_request    = "250m"
proxy_memory_request = "128Mi"
proxy_memory_limit   = "512Mi"
proxy_concurrency    = 2
