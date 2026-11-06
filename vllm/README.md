# vLLM options

Engine/downloader images come from private ECR. One init container downloads the
version-pinned S3 model and verifies its SHA-256 before serving from `/models/model`.
See [ecr/README.md](../ecr/README.md) and [models/README.md](../models/README.md).
`--served-model-name` preserves the public API name. Image and model releases are
selected independently in `ecr/image/release.json` and `models/release.json`.


Deployment settings and selected tuning options for `vllm serve` in **vLLM v0.33.0** (the base version pinned by digest in `ecr/image/release.json`).

- [How options are set in this repository](#how-options-are-set-in-this-repository)
- [Key options explained](#key-options-explained): the options that matter most for this deployment, with explanations for our GPUs
- [Upstream option reference](#upstream-option-reference): complete versioned CLI documentation

## How options are set in this repository

The container image `vllm/vllm-openai` has the entrypoint `vllm serve`. vLLM has no environment variables for these options, so the values are set as **container environment variables** (`SERVE_*`, from `local.serve_env` in [`main.tf`](main.tf)), and the container `args` reference them as `$(NAME)`. Kubernetes substitutes them before starting the container:

```hcl
# Environment variables (deployment variables plus models/release.json)
SERVE_MODEL                  = "/models/model"
SERVE_MODEL_NAME             = "Qwen/Qwen3-4B-Instruct-2507"
SERVE_HOST                   = "0.0.0.0"
SERVE_PORT                   = "8000"
SERVE_DTYPE                  = "half"
SERVE_MAX_MODEL_LEN          = "16384"
SERVE_GPU_MEMORY_UTILIZATION = "0.9"

# Container args
args = [
  "$(SERVE_MODEL)",
  "--served-model-name", "$(SERVE_MODEL_NAME)",
  "--host", "$(SERVE_HOST)",
  "--port", "$(SERVE_PORT)",
  "--dtype", "$(SERVE_DTYPE)",
  "--max-model-len", "$(SERVE_MAX_MODEL_LEN)",
  "--gpu-memory-utilization", "$(SERVE_GPU_MEMORY_UTILIZATION)",
]
```

which runs:

```bash
vllm serve /models/model --served-model-name Qwen/Qwen3-4B-Instruct-2507 --host 0.0.0.0 --port 8000 --dtype half --max-model-len 16384 --gpu-memory-utilization 0.9
```

Check the values in the running pod with `kubectl -n vllm exec deploy/vllm -- env | grep ^SERVE_`.

To use another option:

1. Add a variable in `variables.tf` and its value in `terraform.tfvars`.
2. Add a `SERVE_<OPTION>` entry to `local.serve_env` and `"--<option>", "$(SERVE_<OPTION>)"` to `args` in `main.tf`.
3. Run `terraform apply`. The Deployment rolls one pod at a time with `maxSurge=0` and `maxUnavailable=1`.

Use the `SERVE_` prefix, never `VLLM_`. vLLM v0.33.0 logs `Unknown vLLM environment variable detected` for unknown `VLLM_*` variables (or refuses to start with `--fail-on-environ-validation`). `VLLM_PORT` and `VLLM_HOST_IP` are reserved for vLLM's internal communication, not the API server.

Host and port are set to avoid common misconfigurations:

- `--host 0.0.0.0` (enforced by validation of `host`): vLLM must listen on all interfaces, or the kubelet probes and the Service can't reach it. `::` (IPv6) isn't allowed because the cluster's pod network is IPv4-only.
- `port` (validated to 1024–65535) sets `--port`, the container port, the Service port and the `port_forward` output together. The probes and the Service use the named port `http`, so they follow automatically.
- `enable_service_links = false` in the pod spec: otherwise Kubernetes injects variables for the Service named `vllm`, including `VLLM_PORT=tcp://<ip>:8000`. vLLM reads that as its internal port and fails with `VLLM_PORT ... appears to be a URI`.

Option syntax:

- Boolean options come in pairs: `--enable-prefix-caching` / `--disable-prefix-caching`, `--enforce-eager` / `--no-enforce-eager`.
- Many numbers accept suffixes: `16k` = 16,000, `16K` = 16,384.
- Options marked as JSON take either a JSON string or dotted keys, see [the upstream reference](#upstream-option-reference).
- `--config config.yaml` loads options from a YAML file instead of the command line.

## Key options explained

Values in the **This repo** column are what we pass today; "default" means we don't set it. Hardware notes refer to our GPU nodes: `g4dn.xlarge` (T4, 16 GiB), `g5.xlarge` (A10G, 24 GiB), `g6.xlarge` (L4, 24 GiB).

### Model and precision

| Option | Default | This repo | Explanation |
|---|---|---|---|
| `model` (positional) | `Qwen/Qwen3-0.6B` | `/models/model` | Read-only local weights prepared from the selected S3 archive version. Offline serving uses `--served-model-name Qwen/Qwen3-4B-Instruct-2507` for API compatibility. |
| `--dtype` | `auto` | `half` | Precision of weights and activations. `auto` uses the model's own precision (bf16 for Qwen3). `half` = fp16. The T4 has no bf16 support, so we force fp16 on every node type for consistent behaviour. On g5/g6 you could switch to `bfloat16`. |
| `--quantization`, `-q` | auto-detected | default | Quantization method of the weights (e.g. `awq`, `gptq`, `fp8`). Normally read from the model's config, so you only set it to override. Use it with a quantized model to fit a bigger model on the same GPU. |
| `--revision` | latest | not passed | The publisher selects the upstream commit in `models/release.json`; vLLM reads an already prepared local directory. |
| `--served-model-name` | same as `model` | default | Name clients use in the `model` field of API requests. For example `qwen3-4b` lets clients avoid the full Hugging Face ID and lets you swap models without changing clients. |
| `--trust-remote-code` | `False` | default | Allows running Python code shipped with the model repository. Needed only for models with custom architectures. Qwen3 doesn't need it; keep it off for security. |
| `--generation-config` | `auto` | default | Where default sampling parameters (temperature, top_p, ...) come from. `auto` uses the model's `generation_config.json`, which for Qwen3 holds Qwen's recommended values. `vllm` ignores it and uses vLLM's defaults. Requests can always override them. |
| `--max-logprobs` | `20` | default | Maximum number of log probabilities a request may ask for. |

### GPU memory and KV cache

vLLM takes `gpu-memory-utilization` × total GPU memory. From that it subtracts the model weights and activation memory, and everything left becomes **KV cache**: the memory that stores the attention keys and values of every token in every running request. More KV cache means longer contexts and more requests at once.

For Qwen3-4B in fp16: weights ≈ 7.5 GiB, KV cache ≈ 144 KiB per token (36 layers × 8 KV heads × 128 head dim × 2 for K and V × 2 bytes).

| Option | Default | This repo | Explanation |
|---|---|---|---|
| `--gpu-memory-utilization` | `0.92` | `0.90` | Fraction of GPU memory vLLM may use. On a T4: 0.90 × 15 GiB ≈ 13.3 GiB, minus 7.5 GiB weights and ~1.2 GiB overhead ≈ 4.6 GiB KV cache (~33k tokens). On A10G/L4 ≈ 11.5 GiB (~84k tokens). Raise it for more KV cache; lower it if the pod crashes with CUDA out-of-memory. |
| `--max-model-len` | model's maximum (262,144 for Qwen3-4B-2507) | `16384` | Maximum tokens per request (prompt + output). vLLM refuses to start if the KV cache can't hold one request of this length, so the model's full 256k context would fail on our GPUs. `auto` (or `-1`) picks the largest length that fits. With 16k, a T4 holds 2 full-length requests at once (many more short ones). |
| `--kv-cache-dtype` | `auto` | default | Precision of the KV cache. `auto` = same as `--dtype` (fp16 here). `fp8` variants halve KV memory, which doubles the tokens that fit, with a small quality cost. Support depends on the GPU; check the vLLM quantization docs before using it on a T4. |
| `--kv-cache-memory-bytes` | not set | default | Fixed KV cache size per GPU (e.g. `4G`). When set, `--gpu-memory-utilization` is ignored. Useful for precise control. |
| `--block-size` | platform default | default | Tokens per KV cache block. vLLM stores the cache in fixed-size blocks (PagedAttention) so memory isn't wasted on padding. Rarely needs changing. |
| `--enable-prefix-caching` / `--disable-prefix-caching` | enabled (for supported models) | default (enabled) | Reuses the KV cache of identical prompt prefixes across requests, e.g. a shared system prompt or earlier turns of a chat. Saves compute and speeds up time-to-first-token. |
| `--cpu-offload-gb` | `0` | default | Keeps this many GiB of model weights in CPU RAM and streams them to the GPU on every forward pass. Lets a bigger model "fit", but is slow, and our `g4dn.xlarge` has only 16 GiB RAM. |
| `--kv-offloading-size` | not set | default | Size in GiB of a CPU buffer that KV cache can be moved to when GPU memory is full. Same RAM limit applies. |

### Scheduling and throughput

Each step, vLLM's scheduler builds one batch from all running requests. These options limit that batch.

| Option | Default | This repo | Explanation |
|---|---|---|---|
| `--max-num-seqs` | `256` on our GPUs | default | Maximum number of requests processed together in one step. Requests above this wait in a queue. Lower it to reduce memory pressure; raising it helps only if the KV cache has room for more requests. |
| `--max-num-batched-tokens` | `2048` on our GPUs (API server) | default | Token budget per step, shared by prompt processing (prefill) and generation (decode). Higher values process long prompts faster but make each step slower, which delays tokens of other requests. |
| `--enable-chunked-prefill` / `--disable-chunked-prefill` | enabled (for supported models) | default (enabled) | Splits long prompts into chunks of up to `max-num-batched-tokens`, so one long prompt doesn't stall token generation for everyone else. |
| `--enforce-eager` | `False` | default | Disables CUDA graphs and `torch.compile`. Startup is faster and a few hundred MiB of GPU memory are freed (more KV cache), but generation is slower. Try it on the T4 if memory is tight or startup takes too long. |
| `--seed` | `0` | default | Random seed for sampling, for reproducible outputs. |

### Parallelism

| Option | Default | This repo | Explanation |
|---|---|---|---|
| `--tensor-parallel-size`, `-tp` | `1` | default | Splits each layer across this many GPUs. Our nodes have 1 GPU, so it stays `1`. Use it for models too large for one GPU, on multi-GPU nodes such as `g5.12xlarge`. |
| `--pipeline-parallel-size`, `-pp` | `1` | default | Splits the model's layers into stages on different GPUs or nodes. |
| `--data-parallel-size`, `-dp` | `1` | default | Runs several full copies of the model. On Kubernetes, more Deployment replicas usually achieve the same thing. |

### API server

| Option | Default | This repo | Explanation |
|---|---|---|---|
| `--host` / `--port` | all interfaces / `8000` | `0.0.0.0` / `8000` | Address the HTTP server listens on. Set from the `host` and `port` variables. `port` also sets the container port, Service and probes (see [above](#how-options-are-set-in-this-repository)). |
| `--api-key` | not set | default | Requires `Authorization: Bearer <key>` on `/v1`, `/v2` and `/inference` endpoints. Other endpoints (such as `/invocations`) stay open, so it isn't full security. Our Service is `ClusterIP` (not exposed outside the cluster). If you add a key, pass it from a Kubernetes Secret, not `terraform.tfvars`. |
| `--enable-auto-tool-choice` + `--tool-call-parser` | off | default | Enables tool/function calling in the OpenAI API. Qwen models use Hermes-style tool calls, so for this model: `--enable-auto-tool-choice --tool-call-parser hermes`. |
| `--reasoning-parser` | not set | default | Splits a reasoning model's "thinking" from its answer (`reasoning_content` in the response). `Qwen3-4B-Instruct-2507` is a non-thinking model, so it isn't needed. |
| `--chat-template` | from the tokenizer | default | Custom Jinja chat template. Needed only when the model's own template is missing or wrong. |
| `--uvicorn-log-level` | `info` | default | Log level of the HTTP server. |
| `--disable-log-stats` | `False` | default | Stops the periodic throughput and KV cache usage log lines. They're useful while tuning the options above, so keep them on. Metrics are also available in Prometheus format at `/metrics`. |
| `--enable-log-requests` | `False` | default | Logs each incoming request. Prompts may contain sensitive data. |

### Model-specific: multimodal and LoRA

| Option | Default | This repo | Explanation |
|---|---|---|---|
| `--language-model-only` | `False` | default | Disables image/audio/video inputs of multimodal models, saving the memory for their encoders. Not relevant for Qwen3-4B-Instruct-2507 (text only). |
| `--limit-mm-per-prompt` | model default | default | Maximum number of images/videos/audio items per prompt for multimodal models. |
| `--enable-lora` | `False` | default | Serves LoRA adapters on top of the base model; see the upstream `LoRAConfig` documentation. |

## Upstream option reference

Use the [official vLLM v0.33.0 serve reference](https://docs.vllm.ai/en/v0.33.0/cli/serve/)
for the complete CLI specification. The image's `--help=all` output is authoritative
for the pinned engine. The repository keeps deployment-specific settings here
rather than a copied upstream help dump.
