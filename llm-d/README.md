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
- The plain `Service vllm` (round-robin) still exists, so both can be compared.

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

**Hardening changes:** ingress now accepts gateway pods only; operator port-forward
still works. `router_replicas` controls all-active EPP replicas with rolling updates.
Production overrides use two replicas; their approximate cache indexes remain local.
See [operations guidance](../docs/OPERATIONS.md) and [the change table](../IMPROVEMENTS.md).

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

### Compare routing: llm-d vs round-robin

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

With llm-d, repeated prefixes may favor the same pod; inspect per-pod cache hits
and request distribution rather than assuming perfect affinity. For a fair comparison,
run an in-cluster benchmark against the actual Service addresses, with narrowly
scoped temporary network-policy access granted to a dedicated benchmark identity:

- router: `http://llm-d-epp.vllm.svc.cluster.local:80`
- plain Service: `http://vllm.vllm.svc.cluster.local:8000`

Remove that temporary access after testing. The default policies deliberately block
direct client access to both services. Use multiple connections and concurrent traffic,
and record connection reuse: Kubernetes Service balancing is connection-based, not
strict per-request round-robin. `kubectl port-forward svc/vllm` chooses one pod for
the session, so it cannot test Service distribution across replicas.

## Remove

```bash
terraform destroy
```

This command is now blocked by the CRD `prevent_destroy` guard. CRDs are shared,
cluster-scoped types: deleting one removes all its custom resources. Follow
[the ownership/migration procedure](../docs/OPERATIONS.md) before teardown; do not
remove the guard merely to make destroy succeed.
