# llm-d Router (PoC)

Proof of concept for learning [llm-d](https://llm-d.ai) v1.0.0 ([#12](https://github.com/wlodarczyk-devops/vllm_eks/issues/12)). The llm-d Router runs in **Standalone Mode** in front of the 2 vLLM pods of [`../vllm`](../vllm), with llm-d's **Optimized Baseline** routing.

## How it works

```text
client ──► Service llm-d-epp :80 (ClusterIP)
             │
             ▼
           Pod llm-d-epp  (CPU system node)
           ├── envoy-proxy  :8081  parks the request, asks the EPP over ext-proc (localhost:9002)
           └── epp                 Filter → Score → Pick, returns a pod IP
             │
             ▼  directly to the chosen pod IP (Envoy ORIGINAL_DST)
           vLLM pod #1 (GPU node)   or   vLLM pod #2 (GPU node)
```

- **llm-d is a CPU application.** Only vLLM needs GPUs. The router has a node affinity that keeps it off nodes labelled `nvidia.com/gpu.present` (the GPU nodes are also tainted).
- **InferencePool `llm-d`** (Gateway API Inference Extension CRD): selects the model server pods (`app=vllm`, port 8000) and points to the EPP. The pool, the EPP and the vLLM pods must be in the same namespace, so everything runs in `vllm`.
- **EPP (Endpoint Picker)**: watches the pool's pods, scrapes their vLLM metrics, keeps an approximate index of which prompt prefixes each pod has cached, and picks a pod per request.
- **Envoy** runs as a sidecar in the EPP pod. No Gateway, HTTPRoute or gateway controller is needed.
- The plain `Service vllm` (standard Service balancing) still exists, so both can be compared.

Optimized Baseline scheduling (from `values/optimized-baseline.values.yaml`):

| Plugin | Role |
|---|---|
| `approx-prefix-cache-producer` | Tracks which prefixes were sent to which pod (no vLLM KV events needed) |
| `inflight-load-producer` | Tracks in-flight requests/tokens per pod |
| `prefix-cache-affinity-filter` | Keeps pods that likely have the prompt's prefix cached, unless they're too loaded |
| `token-load-scorer` | Prefers the pod with the lowest token load |

## Files

| File | Content |
|---|---|
| `main.tf` `data "http" "gaie_crds"` | Downloads the InferencePool CRD from the Gateway API Inference Extension release `gaie_version` (v1.6.2, the version llm-d v1.0.0 uses) and checks it against `gaie_manifest_sha256` before applying |
| `values/base.values.yaml` | llm-d's recommended router values, unmodified |
| `values/optimized-baseline.values.yaml` | llm-d's Optimized Baseline values, unmodified |
| `main.tf` | CRD (`kubernetes_manifest`) and the `llm-d-router-standalone` Helm chart with the two values files plus this cluster's overrides (`local.overrides`) |

## Differences from llm-d's recommended settings

| Setting | Recommended | Here | Why |
|---|---|---|---|
| EPP resources | 4 CPU / 8 GiB request, 16 GiB limit | 500m / 512Mi, 1Gi limit | Sized for production traffic; the `t3.medium` system node has ~1.5 CPU free |
| Envoy resources | 4 CPU / 8 GiB request, 16 GiB limit | 250m / 128Mi, 512Mi limit | Same |
| Envoy `--concurrency` | 8 | 2 | Match the smaller CPU request |
| Security context | not set by the chart | non-root UID 65532, read-only root filesystem, no privilege escalation, capabilities dropped, seccomp `RuntimeDefault` | The `vllm` namespace enforces the `restricted` Pod Security Standard; without these the pods are rejected |
| Node placement | not set | not on GPU nodes | Keep GPUs for vLLM |
| Model | `Qwen/Qwen3-32B`, 2 replicas × TP=2 on H100 | `Qwen/Qwen3-4B-Instruct-2507`, 2 replicas × 1 GPU (T4/A10G/L4) | Fits our GPUs and quota |

Not calibrated: `prefix-cache-affinity-filter`'s default `peakPrefillThroughput` (15928) is measured for Qwen3-32B on H100. llm-d's `guides/recipes/router/calibration` describes how to measure it for other hardware.

## Deploy

Requires 2 Ready vLLM pods (2 GPU nodes, `vllm/` with `replicas = 2`).

```bash
cd llm-d
terraform init
terraform apply
```

## Verify

```bash
kubectl -n vllm get inferencepool llm-d -o yaml       # selector, target port, EPP reference
kubectl -n vllm get pods -o wide                       # llm-d-epp on the system node, vllm on GPU nodes
kubectl -n vllm logs deploy/llm-d-epp -c epp -f        # EPP: discovered endpoints, scheduling decisions
```

Send requests through the router:

```bash
$(terraform output -raw port_forward)                  # keep running: localhost:8080 → router
eval "$(terraform output -raw test_request)"           # in another terminal
```

### Compare routing: llm-d vs plain Service

Send the same long-prefix prompt several times and count which vLLM pod served each request (each pod logs `POST /v1/chat/completions`):

```bash
PROMPT=$(printf 'You are a helpful assistant. %.0s' {1..200})
for i in $(seq 1 10); do
  curl -s -o /dev/null localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d "{\"model\": \"Qwen/Qwen3-4B-Instruct-2507\", \"messages\": [{\"role\": \"system\", \"content\": \"$PROMPT\"}, {\"role\": \"user\", \"content\": \"Question $i\"}], \"max_tokens\": 5}"
done
for p in $(kubectl -n vllm get pods -l app=vllm -o name); do
  echo "$p: $(kubectl -n vllm logs $p --since=5m | grep -c 'POST /v1/chat/completions')"
done
```

Repeated prefixes may favor the same pod; compare per-pod requests and prefix-cache
hits in `/metrics`. To compare Service load distribution, run an in-cluster client
against the router and plain Service DNS addresses. `kubectl port-forward svc/vllm`
selects one pod for the session and cannot demonstrate distribution across both
replicas. Kubernetes Service balancing is connection-based, so account for HTTP
connection reuse in the comparison.

## Remove

```bash
terraform destroy
```

This removes the router and the InferencePool CRD; the vLLM pods are not affected.
