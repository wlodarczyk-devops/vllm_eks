region       = "eu-central-1"
cluster_name = "vllm-eks"

# Same namespace, labels and port as the vLLM Deployment in ../vllm
namespace           = "vllm"
model_server_labels = { app = "vllm" }
model_server_port   = 8000

release_name         = "llm-d"
router_chart_version = "v1.0.0"
# GAIE version used by llm-d v1.0.0 (guides/env.sh). When changing it, update the checksum:
#   curl -sL https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/<version>/v1-manifests.yaml | shasum -a 256
gaie_version         = "v1.6.2"
gaie_manifest_sha256 = "f410dfca474608c02903087b47f1ac081706dfb6dfe7f83d00a7cc7e00c4ad0d"

# Router runs on the t3.medium system node (2 vCPU, 4 GiB; ~1.5 CPU free).
# llm-d recommends 4 CPU / 8 GiB each for production traffic.
epp_cpu_request    = "500m"
epp_memory_request = "512Mi"
epp_memory_limit   = "1Gi"

proxy_cpu_request    = "250m"
proxy_memory_request = "128Mi"
proxy_memory_limit   = "512Mi"
proxy_concurrency    = 2
