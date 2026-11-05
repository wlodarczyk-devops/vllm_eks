region       = "eu-central-1"
cluster_name = "vllm-eks"
namespace    = "vllm"

vllm_version = "v0.33.0"
# Resolved from the public registry/model API on 2026-11-05; runtime validation is still required.
image_digest   = "sha256:d825baf9ce4b1b6bfc5ecc7b79880c7e6748c65a72d697ce3d47607aafa84c6e"
model_revision = "cdbee75f17c01a7cc42f958dc650907174af0554"

# One pod per GPU node (eks/ gpu node group: 2 nodes)
replicas = 2

# Per pod: Cluster Autoscaler adds a node (~1 min) + image pull on a new node (~5 min)
# + model download/load/warm-up (up to startup_timeout_seconds = 20 min). Measured ~11 min.
progress_deadline_seconds = 1800

# Graceful shutdown as recommended by llm-d: grace period = preStop + shutdown + 15 s = 75 s
shutdown_timeout_seconds = 45
prestop_sleep_seconds    = 15

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

# Writable volumes on the node disk (GPU node root volume: 100 GiB, vLLM image ~11 GB).
# home holds the ~8 GB model plus vLLM/Triton/torch caches; both are deleted when the pod is removed (container restarts preserve them).
home_size = "30Gi"
tmp_size  = "5Gi"

# Startup probe budget after container start: model (~8 GB) download + load + warm-up
startup_timeout_seconds = 1200

# terraform apply waits this long for the pod to be Ready: image (~11 GB) pull on a new node + startup
rollout_timeout = "60m"
