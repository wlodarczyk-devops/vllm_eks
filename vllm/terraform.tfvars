region       = "eu-central-1"
cluster_name = "vllm-eks"
namespace    = "vllm"

vllm_version = "v0.33.0"

# API server address: all interfaces so probes and the Service reach it
host = "0.0.0.0"
port = 8000

# Apache 2.0, not gated (no HF token needed), 4.0B params, ~7.5 GiB weights in fp16
model = "Qwen/Qwen3-4B-Instruct-2507"
# fp16: T4 (g4dn) has no bf16 support; same setting on g5/g6 for consistent behaviour
dtype = "half"

# KV cache needs ~144 KiB/token; on a T4 ~4.6 GiB is left for ~33k tokens,
# so 16k context leaves room for 2 full-length requests at once
max_model_len          = 16384
gpu_memory_utilization = 0.90

# Sized for the smallest GPU node (g4dn.xlarge: 4 vCPU, 16 GiB RAM)
cpu_request    = "2"
memory_request = "8Gi"
memory_limit   = "12Gi"
shm_size       = "2Gi"

model_cache_host_path = "/opt/huggingface-cache"

# Image (~11 GB) pull + model (~8 GB) download + load on first start
startup_timeout_seconds = 1200
