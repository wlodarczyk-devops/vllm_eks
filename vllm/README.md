# vLLM options

Engine/downloader images come from private ECR. One init container downloads the
version-pinned S3 model and verifies its SHA-256 before serving from `/models/model`.
See [ecr/README.md](../ecr/README.md) and [models/README.md](../models/README.md).
`--served-model-name` preserves the public API name. Image and model releases are
selected independently in `ecr/image/release.json` and `models/release.json`.


Reference for every option of `vllm serve` in **vLLM v0.33.0** (the base version pinned by digest in `ecr/image/release.json`).

- [How options are set in this repository](#how-options-are-set-in-this-repository)
- [Key options explained](#key-options-explained): the options that matter most for this deployment, with explanations for our GPUs
- [Full option reference](#full-option-reference): all 320 options, grouped as in `vllm serve --help`

## How options are set in this repository

The container image `vllm/vllm-openai` has the entrypoint `vllm serve`. vLLM has no environment variables for these options, so the values are set as **container environment variables** (`SERVE_*`, from `local.serve_env` in [`main.tf`](main.tf)), and the container `args` reference them as `$(NAME)`. Kubernetes substitutes them before starting the container:

```hcl
# Environment variables (values from terraform.tfvars)
SERVE_MODEL                  = "Qwen/Qwen3-4B-Instruct-2507"
SERVE_HOST                   = "0.0.0.0"
SERVE_PORT                   = "8000"
SERVE_DTYPE                  = "half"
SERVE_MAX_MODEL_LEN          = "16384"
SERVE_GPU_MEMORY_UTILIZATION = "0.9"

# Container args
args = [
  "$(SERVE_MODEL)",
  "--host", "$(SERVE_HOST)",
  "--port", "$(SERVE_PORT)",
  "--dtype", "$(SERVE_DTYPE)",
  "--max-model-len", "$(SERVE_MAX_MODEL_LEN)",
  "--gpu-memory-utilization", "$(SERVE_GPU_MEMORY_UTILIZATION)",
]
```

which runs:

```bash
vllm serve Qwen/Qwen3-4B-Instruct-2507 --host 0.0.0.0 --port 8000 --dtype half --max-model-len 16384 --gpu-memory-utilization 0.9
```

Check the values in the running pod with `kubectl -n vllm exec deploy/vllm -- env | grep ^SERVE_`.

To use another option:

1. Add a variable in `variables.tf` and its value in `terraform.tfvars`.
2. Add a `SERVE_<OPTION>` entry to `local.serve_env` and `"--<option>", "$(SERVE_<OPTION>)"` to `args` in `main.tf`.
3. Run `terraform apply`. The Deployment uses the `Recreate` strategy, so the pod restarts with the new options.

Use the `SERVE_` prefix, never `VLLM_`. vLLM v0.33.0 logs `Unknown vLLM environment variable detected` for unknown `VLLM_*` variables (or refuses to start with `--fail-on-environ-validation`). `VLLM_PORT` and `VLLM_HOST_IP` are reserved for vLLM's internal communication, not the API server.

Host and port are set to avoid common misconfigurations:

- `--host 0.0.0.0` (enforced by validation of `host`): vLLM must listen on all interfaces, or the kubelet probes and the Service can't reach it. `::` (IPv6) isn't allowed because the cluster's pod network is IPv4-only.
- `port` (validated to 1024–65535) sets `--port`, the container port, the Service port and the `port_forward` output together. The probes and the Service use the named port `http`, so they follow automatically.
- `enable_service_links = false` in the pod spec: otherwise Kubernetes injects variables for the Service named `vllm`, including `VLLM_PORT=tcp://<ip>:8000`. vLLM reads that as its internal port and fails with `VLLM_PORT ... appears to be a URI`.

Option syntax:

- Boolean options come in pairs: `--enable-prefix-caching` / `--disable-prefix-caching`, `--enforce-eager` / `--no-enforce-eager`.
- Many numbers accept suffixes: `16k` = 16,000, `16K` = 16,384.
- Options marked as JSON take either a JSON string or dotted keys, see [JSON CLI arguments](#json-cli-arguments).
- `--config config.yaml` loads options from a YAML file instead of the command line.

## Key options explained

Values in the **This repo** column are what we pass today; "default" means we don't set it. Hardware notes refer to our GPU nodes: `g4dn.xlarge` (T4, 16 GiB), `g5.xlarge` (A10G, 24 GiB), `g6.xlarge` (L4, 24 GiB).

### Model and precision

| Option | Default | This repo | Explanation |
|---|---|---|---|
| `model` (positional) | `Qwen/Qwen3-0.6B` | `/models/model` | Read-only local weights prepared from the selected S3 archive version. Offline serving uses `--served-model-name Qwen/Qwen3-4B-Instruct-2507` for API compatibility. |
| `--dtype` | `auto` | `half` | Precision of weights and activations. `auto` uses the model's own precision (bf16 for Qwen3). `half` = fp16. The T4 has no bf16 support, so we force fp16 on every node type for consistent behaviour. On g5/g6 you could switch to `bfloat16`. |
| `--quantization`, `-q` | auto-detected | default | Quantization method of the weights (e.g. `awq`, `gptq`, `fp8`). Normally read from the model's config, so you only set it to override. Use it with a quantized model to fit a bigger model on the same GPU. |
| `--revision` | latest | default | Git revision (branch, tag or commit) of the model on Hugging Face. Pin a commit for reproducible deployments. |
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
| `--enable-lora` | `False` | default | Serves LoRA adapters on top of the base model; see the `LoRAConfig` group below. |

## Full option reference

Generated from the official [`vllm serve` CLI reference for v0.33.0](https://docs.vllm.ai/en/v0.33.0/cli/serve.html). The explanation of each option is vLLM's own help text. For other versions, run `docker run --rm vllm/vllm-openai:<tag> --help=all`.

Groups: [Arguments](#arguments) (12) · [Frontend](#frontend) (62) · [ModelConfig](#modelconfig) (47) · [LoadConfig](#loadconfig) (9) · [AttentionConfig](#attentionconfig) (1) · [MambaConfig](#mambaconfig) (4) · [StructuredOutputsConfig](#structuredoutputsconfig) (2) · [ParallelConfig](#parallelconfig) (53) · [CacheConfig](#cacheconfig) (21) · [OffloadConfig](#offloadconfig) (7) · [MultiModalConfig](#multimodalconfig) (24) · [LoRAConfig](#loraconfig) (13) · [LoggingConfig](#loggingconfig) (3) · [ObservabilityConfig](#observabilityconfig) (13) · [SchedulerConfig](#schedulerconfig) (18) · [CompilationConfig](#compilationconfig) (2) · [KernelConfig](#kernelconfig) (6) · [VllmConfig](#vllmconfig) (23)

### JSON CLI Arguments

When passing JSON CLI arguments, the following sets of arguments are equivalent:

- `--json-arg '{"key1": "value1", "key2": {"key3": "value2"}}'`

- `--json-arg.key1 value1 --json-arg.key2.key3 value2`

Additionally, list elements can be passed individually using `+`:

- `--json-arg '{"key4": ["value3", "value4", "value5"]}'`

- `--json-arg.key4+ value3 --json-arg.key4+='value4,value5'`

### Arguments

#### `--headless`

Run in headless mode. See multi-node data parallel documentation for more details.
**Default:** `False`

#### `--api-server-count`, `-asc`

How many API server processes to run. Defaults to data_parallel_size if not specified.

#### `--config`

Read CLI options from a config file. Must be a YAML with the following options: [configuration/serve_args](https://docs.vllm.ai/en/configuration/serve_args/)

#### `--grpc`

Launch the Python gRPC (SMG VllmEngine) server on --port instead of the HTTP OpenAI-compatible server. Requires: pip install vllm[grpc]. Cannot be combined with --grpc-port, which enables the Rust frontend's gRPC services.
**Default:** `False`

#### `--disable-log-stats`

Disable logging statistics.
**Default:** `False`

#### `--aggregate-engine-logging`

Log aggregate rather than per-engine statistics when using data parallelism.
**Default:** `False`

#### `--fail-on-environ-validation`, `--no-fail-on-environ-validation`

If set, the engine will raise an error if environment validation fails.
**Default:** `False`

#### `--shutdown-timeout`

Shutdown timeout in seconds. 0 = abort, >0 = wait.
**Default:** `0`

#### `--gdn-prefill-backend`

**Choices:** `flashinfer`, `triton`, `cutedsl`, `aiter_flydsl`, `sycl`
Select GDN prefill backend.

#### `--kda-prefill-backend`

**Choices:** `auto`, `triton`, `flashkda`, `flashinfer`, `fused`
Select KDA prefill backend. 'flashkda' is CUDA-only and 'fused' is ROCm-only; 'auto' picks a supported backend.

#### `--kda-decode-backend`

**Choices:** `auto`, `native`, `flashinfer`, `triton`
Select KDA decode backend.

#### `--enable-log-requests`, `--disable-log-requests`

Enable logging request information, dependent on log level:
- INFO: Request ID, parameters and LoRA request.
- DEBUG: Prompt inputs (e.g: text, token IDs).
You can set the minimum log level via `VLLM_LOGGING_LEVEL`.
You can also set a separate log level for request JSON body via `VLLM_REQUEST_BODY_LOG_LEVEL` (default: DEBUG).
**Default:** `False`

### Frontend

Arguments for the OpenAI-compatible frontend server.

#### `--lora-modules`

LoRA modules configurations in either 'name=path' format or JSON format
or JSON list format. Example (old format): `'name=path'` Example (new
format): `{"name": "name", "path": "lora_path",
"base_model_name": "id"}`

#### `--chat-template`

The file path to the chat template, or the template in single-line form
for the specified model.

#### `--chat-template-content-format`

**Choices:** `auto`, `openai`, `string`

The format to render message content within a chat template.

- "string" will render the content as a string. Example: `"Hello World"`

- "openai" will render the content as a list of dictionaries, similar to
  OpenAI schema. Example: `[{"type": "text", "text": "Hello world!"}]`

**Default:** `auto`

#### `--trust-request-chat-template`, `--no-trust-request-chat-template`

Whether to trust the chat template provided in the request. If False,
the server will always use the chat template specified by `--chat-template`
or the ones from tokenizer.
**Default:** `False`

#### `--trust-request-mm-kwargs`, `--no-trust-request-mm-kwargs`

Whether to trust per-request multimodal kwargs (`mm_processor_kwargs`
and `media_io_kwargs`). If False, the server rejects non-empty values
because they can change multimodal preprocessing resource usage. Only
enable this when API clients are trusted.
**Default:** `False`

#### `--default-chat-template-kwargs`

Default keyword arguments to pass to the chat template renderer.
These will be merged with request-level chat_template_kwargs,
with request values taking precedence. Useful for setting default
behavior for reasoning models. Example: '{"enable_thinking": false}'
to disable thinking mode by default for Qwen3/DeepSeek models.

Should either be a valid JSON string or JSON keys passed individually.

#### `--reasoning-effort-map`

JSON mapping that rewrites a request's reasoning effort to a value the
chat template supports, for templates that silently fall back on efforts
they do not recognize. Applies to the effort set through the Chat
Completions, Responses and Anthropic Messages APIs; efforts not listed
pass through unchanged. Example: '{"medium": "low", "xhigh": "max"}'
for a template that only knows low, high and max.

Should either be a valid JSON string or JSON keys passed individually.

#### `--response-role`

The role name to return if `request.add_generation_prompt=true`.
**Default:** `assistant`

#### `--return-tokens-as-token-ids`, `--no-return-tokens-as-token-ids`

When `--max-logprobs` is specified, represents single tokens as
strings of the form 'token_id:{token_id}' so that tokens that are not
JSON-encodable can be identified.
**Default:** `False`

#### `--enable-auto-tool-choice`, `--disable-auto-tool-choice`

Enable auto tool choice for supported models. Use `--tool-call-parser`
to specify which parser to use.
**Default:** `False`

#### `--exclude-tools-when-tool-choice-none`, `--no-exclude-tools-when-tool-choice-none`

If specified, exclude tool definitions in prompts when
tool_choice='none'.
**Default:** `False`

#### `--tool-call-parser`

Select the tool call parser depending on the model that you're using.
This is used to parse the model-generated tool call into OpenAI API format.
Required for `--enable-auto-tool-choice`. You can choose any option from
the built-in parsers or register a plugin via `--tool-parser-plugin`.

#### `--tool-parser-plugin`

Special the tool parser plugin write to parse the model-generated tool
into OpenAI API format, the name register in this plugin can be used in
`--tool-call-parser`.
**Default:** `""`

#### `--tool-strict-level`

**Choices:** `auto`, `function`, `parameter`, `None`
Server-side floor for structural-tag based tool calling, applied on top
of the per-tool `strict` field. `auto` follows the request's tool choice
and per-tool strictness; `function` constrains the
tool-call envelope (markup and function name) for every request with
tools; `parameter` additionally pins argument schemas, as if every tool
were `strict: true`. When unset, the tool parser's default level applies,
which is `auto` for most parsers.

#### `--tool-server`

Comma-separated list of host:port pairs (IPv4, IPv6, or hostname).
Examples: 127.0.0.1:8000, [::1]:8000, localhost:1234. Or `demo` for
built-in demo tools (browser and Python code interpreter). WARNING:
The `demo` Python tool executes model-generated code in Docker without
network isolation by default. See the security guide for more
information.

#### `--max-log-len`

Max number of prompt characters or prompt ID numbers being printed in
log. The default of None means unlimited.

#### `--enable-prompt-tokens-details`, `--disable-prompt-tokens-details`

If set to True, enable prompt_tokens_details in usage.
**Default:** `False`

#### `--enable-per-request-metrics`, `--disable-per-request-metrics`

If set to True, include per-request timing metrics in API responses.
**Default:** `False`

#### `--enable-server-load-tracking`, `--disable-server-load-tracking`

If set to True, enable tracking server_load_metrics in the app state.
**Default:** `False`

#### `--enable-force-include-usage`, `--disable-force-include-usage`

If set to True, including usage on every request.
**Default:** `False`

#### `--sse-keep-alive-interval`

Send an SSE keep-alive comment line every this many seconds when a
`/v1/chat/completions` or `/v1/completions` streaming response is idle
(queued, prefill, or between tokens), to prevent reverse proxies/tunnels
with read timeouts from closing the connection. Defaults to 0, which
disables keep-alive comments entirely.
**Default:** `0`

#### `--enable-tokenizer-info-endpoint`, `--disable-tokenizer-info-endpoint`

Enable the `/tokenizer_info` endpoint. May expose chat
templates and other tokenizer configuration.
**Default:** `False`

#### `--enable-log-outputs`, `--disable-log-outputs`

If set to True, log model outputs (generations). Requires
`--enable-log-requests`. Output text and finish reasons are logged at INFO,
while output token IDs are logged at DEBUG.
**Default:** `False`

#### `--enable-log-deltas`, `--disable-log-deltas`

If set to False, output deltas will not be logged. Relevant only if
--enable-log-outputs is set.
**Default:** `True`

#### `--cohere-is-reasoning-model`, `--no-cohere-is-reasoning-model`

Cohere `/cohere/v2/chat` only. Whether the served model is a
reasoning Command-family model. When True (default), the assistant's
chain-of-thought is surfaced as a `thinking` content block (or
`content-*` events on the stream). When False, reasoning is
surfaced as Cohere's `tool_plan` field (or `tool-plan-delta`
events) whenever the model emits tool calls, matching older non-
reasoning Command models. Has no effect on the non-Cohere
endpoints.
**Default:** `True`

#### `--cohere-format`

Cohere `--tokenizer-mode cohere` only. Which Cohere prompt
format to render: `cmd4` (current Command A+ models; default) or
`cmd3` (earlier Cmd-A and Cmd-A reasoning models). Selecting the
wrong format silently produces a prompt the model wasn't trained
on, which most commonly manifests as the model emitting text but no
citations / tool calls / thinking blocks. Equivalent to passing
`--default-chat-template-kwargs '{"cohere_format": "..."}'` -- any
explicit request-level `chat_template_kwargs.cohere_format` takes
priority.
**Default:** `cmd4`

#### `--anthropic-disabled-thinking-effort`

**Choices:** `auto`, `high`, `low`, `max`, `medium`, `none`, `xhigh`
The `reasoning_effort` used for Anthropic Messages, token counting,
and render requests with `thinking: {"type": "disabled"}`.
`none` turns thinking off for models that support it; `low` suits
models that always think
(e.g. GLM-5.3) or reject `none` (e.g. gpt-oss). `auto` (default) uses
`low` when the renderer rejects `none` or renders it the same as a
thinking effort, and `none` otherwise.
**Default:** `auto`

#### `--log-error-stack`, `--no-log-error-stack`

If set to True, log the stack trace of error responses
**Default:** `False`

#### `--tokens-only`, `--no-tokens-only`

If set to True, only enable the Tokens In<>Out endpoint.
This is intended for use in a Disaggregated Everything setup.
**Default:** `False`

#### `--enable-scale-out`, `--disable-scale-out`

If set to True, register the scale-out endpoints (`/render`, `/derender`,
`/inference/v1/generate` and `/inference/v1/abort_requests`) on `vllm serve`.
Has no effect on `vllm launch render` or `vllm serve --tokens-only` which
always register their required endpoints regardless of this flag.
**Default:** `False`

#### `--fingerprint-mode`

**Choices:** `custom`, `full`, `hash`, `none`

Controls the `system_fingerprint` field on responses.

- `full` (default): `vllm-<version>[-<parallelism>]-<hash8>`. Encodes
  server version, non-trivial parallelism degrees (tp/pp/dp/ep), and an
  8-char config hash.

- `hash`: `vllm-<version>-<hash8>`. Parallelism stripped.

- `custom`: emits the literal string from `--fingerprint-value`.

- `none`: the field is omitted (serialized as `null`).

**Default:** `full`

#### `--fingerprint-value`

Literal fingerprint string used when `--fingerprint-mode=custom`.

#### `--host`

Host name.

#### `--port`

Port number.
**Default:** `8000`

#### `--grpc-port`

Enable the Rust frontend's additional gRPC Inference and Control services
on this port. Requires `VLLM_USE_RUST_FRONTEND=1 vllm serve`; HTTP remains on
`--port`. Binds on `--host`, or 127.0.0.1 with `--uds`. Cannot be combined
with the Python gRPC server's `--grpc` flag.

#### `--data-parallel-supervisor-port`

HTTP port for aggregated health endpoints in multi-port external LB
mode.
**Default:** `9256`

#### `--dp-supervisor-probe-interval-s`

Seconds between aggregated health probes in multi-port external LB mode.
**Default:** `5.0`

#### `--dp-supervisor-probe-timeout-s`

Seconds to wait between retries when a child health probe fails with a
connection error in multi-port external LB mode.
**Default:** `5.0`

#### `--dp-supervisor-probe-failure-threshold`

Number of consecutive connection-error retries before a child health
probe is declared failed in multi-port external LB mode.
**Default:** `3`

#### `--uds`

Unix domain socket path. If set, host and port arguments are ignored.

#### `--uvicorn-log-level`

**Choices:** `critical`, `debug`, `error`, `info`, `trace`, `warning`
Log level for uvicorn.
**Default:** `info`

#### `--disable-uvicorn-access-log`, `--enable-uvicorn-access-log`

Disable uvicorn access log.
**Default:** `False`

#### `--disable-access-log-for-endpoints`

Comma-separated list of endpoint paths to exclude from uvicorn access
logs. This is useful to reduce log noise from high-frequency endpoints
like health checks. Example: "/health,/metrics,/ping".
When set, access logs for requests to these paths will be suppressed
while keeping logs for other endpoints.

#### `--allow-credentials`, `--no-allow-credentials`

Allow credentials.
**Default:** `False`

#### `--allowed-origins`

Allowed origins. Cross-origin browser access is disabled by default.
**Default:** `[]`

#### `--allowed-methods`

Allowed methods.
**Default:** `['*']`

#### `--allowed-headers`

Allowed headers.
**Default:** `['*']`

#### `--api-key`

If provided, the server will require one of these keys to be presented in
the header.

Warning: this only authenticates endpoints under the `/v1`, `/v2`, and
`/inference` path prefixes. Other endpoints on the same server, including
`/invocations` (which exposes the same inference capabilities as `/v1`),
remain unauthenticated. Do not rely on `--api-key` alone to secure vLLM;
see
[usage/security](https://docs.vllm.ai/en/usage/security/#api-key-authentication-limitations)
for what it does and does not protect.

#### `--ssl-keyfile`

The file path to the SSL key file.

#### `--ssl-certfile`

The file path to the SSL cert file.

#### `--ssl-ca-certs`

The CA certificates file.

#### `--enable-ssl-refresh`, `--disable-ssl-refresh`

Refresh SSL Context when SSL certificate files change
**Default:** `False`

#### `--ssl-cert-reqs`

Whether client certificate is required (see stdlib ssl module's).
**Default:** `0`

#### `--ssl-ciphers`

SSL cipher suites for HTTPS (TLS 1.2 and below only).
Example: 'ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305'

#### `--root-path`

FastAPI root_path when app is behind a path based routing proxy.

#### `--middleware`

Additional ASGI middleware to apply to the app. We accept multiple
--middleware arguments. The value should be an import path. If a function
is provided, vLLM will add it to the server using
`@app.middleware('http')`. If a class is provided, vLLM will
add it to the server using `app.add_middleware()`.
**Default:** `[]`

#### `--enable-request-id-headers`, `--disable-request-id-headers`

If specified, API server will add X-Request-Id header to responses.
**Default:** `False`

#### `--disable-fastapi-docs`, `--enable-fastapi-docs`

Disable FastAPI's OpenAPI schema, Swagger UI, and ReDoc endpoint.
**Default:** `False`

#### `--h11-max-incomplete-event-size`

Maximum size (bytes) of an incomplete HTTP event (header or body) for
h11 parser. Helps mitigate header abuse. Default: 4194304 (4 MB).
**Default:** `4194304`

#### `--h11-max-header-count`

Maximum number of HTTP headers allowed in a request for h11 parser.
Helps mitigate header abuse. Default: 256.
**Default:** `256`

#### `--enable-offline-docs`, `--disable-offline-docs`

Enable offline FastAPI documentation for air-gapped environments.
Uses vendored static assets bundled with vLLM.
**Default:** `False`

#### `--enable-flash-late-interaction`, `--disable-flash-late-interaction`

If set, run pooling score MaxSim on GPU in the API server process.
Can significantly improve late-interaction scoring performance.
When disabled, the setting is also propagated to the engine's
[`PoolerConfig`](https://docs.vllm.ai/en/api/vllm/config/pooler/#vllm.config.pooler.PoolerConfig), so the engine-side scorer uses the reference MaxSim
path instead of the fused Triton kernel.
**Default:** `True`

### ModelConfig

Configuration for the model.

#### `--model`

Name or path of the Hugging Face model to use. It is also used as the
content for `model_name` tag in metrics output when `served_model_name` is
not specified.
**Default:** `Qwen/Qwen3-0.6B`

#### `--runner`

**Choices:** `auto`, `draft`, `generate`, `pooling`
The type of model runner to use. Each vLLM instance only supports one
model runner, even if the same model can be used for multiple types.
**Default:** `auto`

#### `--convert`

**Choices:** `auto`, `classify`, `embed`, `none`
Convert the model using adapters defined in
[vllm.model_executor.models.adapters](https://docs.vllm.ai/en/api/vllm/model_executor/models/adapters/#vllm.model_executor.models.adapters). The most common use case is to
adapt a text generation model to be used for pooling tasks.
**Default:** `auto`

#### `--tokenizer`

Name or path of the Hugging Face tokenizer to use. If unspecified, model
name or path will be used.

#### `--tokenizer-mode`

**Choices:** `alpamayo2_super`, `auto`, `cohere`, `deepseek_v32`, `deepseek_v4`, `hf`, `inkling`, `kimi_k3`, `mistral`

Tokenizer mode:

- "auto" will use the tokenizer from `mistral_common` for Mistral models
  if available, otherwise it will use the "hf" tokenizer.

- "hf" will use the fast tokenizer if available.

- "alpamayo2_super" uses the "hf" tokenizer with Alpamayo 2 Super's
  trajectory and special tokens added; selected automatically for
  `nvidia/Alpamayo2-Super`.

- "mistral" will always use the tokenizer from `mistral_common`.

- "deepseek_v32" will always use the tokenizer from `deepseek_v32`.

- "deepseek_v4" will always use the tokenizer from `deepseek_v4`.

- "deepseek_v41" will use the DeepSeek V4.1 prompt encoder.

- "kimi_k3" will always use the "hf" tokenizer but render chat prompts
  with Kimi K3's Python XTML encoding instead of a Jinja template.

- "cohere" uses the standard HF tokenizer but renders the chat template
  via the `cohere_melody` library (cmd3 / cmd4 templates) instead of
  Jinja, and surfaces grounded-citation metadata on responses.

- Other custom values can be supported via plugins.

To swap the Rust BPE backend that powers HF fast tokenizers for the
[fastokens](https://github.com/crusoecloud/fastokens) implementation, set
`VLLM_USE_FASTOKENS=1` instead — that override applies to any mode that
loads an HF fast tokenizer (`hf`, `deepseek_v32`, `deepseek_v4`, …).

**Default:** `auto`

#### `--trust-remote-code`, `--no-trust-remote-code`

Trust remote code (e.g., from HuggingFace) when downloading the model
and tokenizer.
**Default:** `False`

#### `--dtype`

**Choices:** `auto`, `bfloat16`, `float`, `float16`, `float32`, `half`

Data type for model weights and activations:

- "auto" will use FP16 precision for FP32 and FP16 models, and BF16
  precision for BF16 models.

- "half" for FP16. Recommended for AWQ quantization.

- "float16" is the same as "half".

- "bfloat16" for a balance between precision and range.

- "float" is shorthand for FP32 precision.

- "float32" for FP32 precision.

**Default:** `auto`

#### `--seed`

Random seed for reproducibility.

We must set the global seed because otherwise,
different tensor parallel workers would sample different tokens,
leading to inconsistent results.

**Default:** `0`

#### `--hf-config-path`

Name or path of the Hugging Face config to use. If unspecified, model
name or path will be used.

#### `--allowed-local-media-path`

Allowing API requests to read local images or videos from directories
specified by the server file system. This is a security risk. Should only
be enabled in trusted environments.
**Default:** `""`

#### `--allowed-media-domains`

If set, only media URLs that belong to this domain can be used for
multi-modal inputs.

#### `--revision`

The specific model version to use. It can be a branch name, a tag name,
or a commit id. If unspecified, will use the default version.

#### `--code-revision`

The specific revision to use for the model code on the Hugging Face Hub.
It can be a branch name, a tag name, or a commit id. If unspecified, will
use the default version.

#### `--tokenizer-revision`

The specific revision to use for the tokenizer on the Hugging Face Hub.
It can be a branch name, a tag name, or a commit id. If unspecified, will
use the default version.

#### `--max-model-len`

Model context length (prompt and output). If unspecified, will be
automatically derived from the model config.

When passing via `--max-model-len`, supports k/m/g/K/M/G in human-readable
format. Examples:

- 1k -> 1000

- 1K -> 1024

- 25.6k -> 25,600

- -1 or 'auto' -> Automatically choose the maximum model length that fits in
  GPU memory. This will use the model's maximum context length if it fits,
  otherwise it will find the largest length that can be accommodated.

Parse human-readable integers like '1k', '2M', etc.
    Including decimal values with decimal multipliers.
    Also accepts -1 or 'auto' as a special value for auto-detection.

```
Examples:
- '1k' -> 1,000
- '1K' -> 1,024
- '25.6k' -> 25,600
- '-1' or 'auto' -> -1 (special value for auto-detection)
```

#### `--quantization`, `-q`

Method used to quantize the weights. If `None`, we first check the
`quantization_config` attribute in the model config file. If that is
`None`, we assume the model weights are not quantized and use `dtype` to
determine the data type of the weights.

#### `--quantization-config`

User-facing quantization configuration. Carries per-layer-kind specs
(linear, moe) and ignore patterns; see :class:[`QuantizationConfigArgs`](https://docs.vllm.ai/en/api/vllm/config/quantization/#vllm.config.quantization.QuantizationConfigArgs).
Auto-populated from the matching online shorthand when `quantization` is
one of the values in `ONLINE_QUANT_SHORTHAND_NAMES`.

Should either be a valid JSON string or JSON keys passed individually.

#### `--allow-deprecated-quantization`, `--no-allow-deprecated-quantization`

Whether to allow deprecated quantization methods.
**Default:** `False`

#### `--enforce-eager`, `--no-enforce-eager`

Whether to always use eager-mode PyTorch. If True, we will disable CUDA
graph and always execute the model in eager mode. If False, we will use
CUDA graph and eager execution in hybrid for maximal performance and
flexibility.

NOTE: This disables both `torch.compile` and CUDA graphs, and is
equivalent to setting `-cc.mode=none -cc.cudagraph_mode=none`.

**Default:** `False`

#### `--enable-return-routed-experts`, `--disable-return-routed-experts`

Capture and return routed-experts auxiliary outputs.
**Default:** `False`

#### `--return-sampling-mask`, `--no-return-sampling-mask`

Whether to return the post-processing token support for each sample.
**Default:** `False`

#### `--max-logprobs`

Maximum number of log probabilities to return when `logprobs` is
specified in [`SamplingParams`](https://docs.vllm.ai/en/api/vllm/sampling_params/#vllm.sampling_params.SamplingParams). The default value comes the default for the
OpenAI Chat Completions API. -1 means no cap, i.e. all (output_length *
vocab_size) logprobs are allowed to be returned and it may cause OOM.
**Default:** `20`

#### `--logprobs-mode`

**Choices:** `processed_logits`, `processed_logprobs`, `raw_logits`, `raw_logprobs`
Indicates the content returned in the logprobs and prompt_logprobs.
Supported mode:
1) raw_logprobs, 2) processed_logprobs, 3) raw_logits, 4) processed_logits.
Raw means the values before applying any logit processors, like bad words.
Processed means the values after applying all processors, including
temperature and top_k/top_p.
Note: for prompt_logprobs, processed_ and raw_ yield identical results
because prompt tokens do not go through sampling processors.
**Default:** `raw_logprobs`

#### `--use-fp64-gumbel`, `--no-use-fp64-gumbel`

Whether to use FP64 (instead of FP32) random noise for Gumbel-max and
equivalent exponential-race sampling. FP64 preserves lower-tail sampling
events that fp32 uniform/exponential draws can truncate, at the cost of
significantly lower throughput on most GPUs.
**Default:** `False`

#### `--enable-trace-replay`, `--disable-trace-replay`

Whether to allow requests to set
`SamplingParams.trace_decode_token_ids`, which forces decoding to follow a
predetermined token sequence while still computing real logprobs. Reserved
for debugging and RL workflows: enabling it reserves a per-request trace
buffer, so it is off by default.
**Default:** `False`

#### `--disable-sliding-window`, `--enable-sliding-window`

Whether to disable sliding window. If True, we will disable the sliding
window functionality of the model, capping to sliding window size. If the
model does not support sliding window, this argument is ignored.
**Default:** `False`

#### `--disable-cascade-attn`, `--enable-cascade-attn`

--disable-cascade-attn is deprecated and has no effect since cascade attention has been removed. It will be removed in v0.33.0.

#### `--skip-tokenizer-init`, `--no-skip-tokenizer-init`

Skip initialization of tokenizer and detokenizer. Expects valid
`prompt_token_ids` and `None` for prompt from the input. The generated
output will contain token ids.
**Default:** `False`

#### `--enable-prompt-embeds`, `--disable-prompt-embeds`

If `True`, enables passing text embeddings as inputs via the
`prompt_embeds` key.

WARNING: The vLLM engine may crash if incorrect shape of embeddings is passed.
Only enable this flag for trusted users!

**Default:** `False`

#### `--served-model-name`

The model name(s) used in the API. If multiple names are provided, the
server will respond to any of the provided names. The model name in the
model field of a response will be the first name in this list. If not
specified, the model name will be the same as the `--model` argument. Noted
that this name(s) will also be used in `model_name` tag content of
prometheus metrics, if multiple names provided, metrics tag will take the
first one.

#### `--config-format`

**Choices:** `auto`, `hf`, `mistral`

The format of the model config to load:

- "auto" will try to load the config in hf format if available after trying
  to load in mistral format.

- "hf" will load the config in hf format.

- "mistral" will load the config in mistral format.

**Default:** `auto`

#### `--hf-token`

The token to use as HTTP bearer authorization for remote files . If
`True`, will use the token generated when running `hf auth login`
(stored in `~/.cache/huggingface/token`).

#### `--hf-overrides`

If a dictionary, contains arguments to be forwarded to the Hugging Face
config. If a callable, it is called to update the HuggingFace config.
**Default:** `{}`

#### `--model-class-overrides`

Override the model class used for one or more architectures, mapping the
architecture name to a `"module:class"` target (the same format accepted by
`ModelRegistry.register_model`). This registers the target class at runtime,
e.g. `{"GlmMoeDsaForCausalLM":
"vllm.models.deepseek_v32.nvidia.model:DeepseekV32ForCausalLM"}`. This
argument is for development and debugging purposes only.

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `{}`

#### `--pooler-config`

Pooler config which controls the behaviour of output pooling in pooling
models.

API docs: [`vllm.config.PoolerConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.PoolerConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--generation-config`

The folder path to the generation config. Defaults to `"auto"`, the
generation config will be loaded from model path. If set to `"vllm"`, no
generation config is loaded, vLLM defaults will be used. If set to a folder
path, the generation config will be loaded from the specified folder path.
If `max_new_tokens` is specified in generation config, then it sets a
server-wide limit on the number of output tokens for all requests.
**Default:** `auto`

#### `--override-generation-config`

Overrides or sets generation config. e.g. `{"temperature": 0.5}`. If
used with `--generation-config auto`, the override parameters will be
merged with the default config from the model. If used with
`--generation-config vllm`, only the override parameters are used.

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `{}`

#### `--enable-sleep-mode`, `--disable-sleep-mode`

Enable sleep mode for the engine (only cuda and
hip platforms are supported).
**Default:** `False`

#### `--sleep-mode-backend`

Mechanism used to free and restore GPU state for sleep mode. `"cumem"`
(default) uses the built-in `CuMemAllocator` and is behavior-compatible
with prior releases. Additional backends (CUDA checkpoint, CRIU, durable
snapshot) may be registered in-tree or by plugins (RFC #34303).
**Default:** `cumem`

#### `--sleep-mode-offload-cudagraph`, `--no-sleep-mode-offload-cudagraph`

Back up CUDA graph memory to CPU during sleep, restored in place on wake.
Takes effect with enable_sleep_mode, the cumem backend and CUDA graphs.
**Default:** `False`

#### `--sleep-preserve-parameter-names`

Parameter-name globs to preserve across level-2 sleep.
Use target globs for frozen Engram table weights and scales omitted by the
trainer (e.g. `*.engram.embed_tokens.weight*`).
Use `draft.<name>` for draft-private parameters, or `draft.*` for all.
The sender must omit these parameters; loaders must preserve their storage.
**Default:** `[]`

#### `--enable-cumem-allocator`, `--disable-cumem-allocator`

Enable the custom cumem allocator to leverage advanced GPU memory
allocation features such as multi-node NVLink support.

Sleep mode automatically enables this allocator. Only cuda and hip
platforms are supported.

**Default:** `False`

#### `--enable-nccl-comm-suspend`, `--disable-nccl-comm-suspend`

Enable releasing NCCL communicator memory during sleep mode
(`ncclCommSuspend`/`ncclCommResume`). Experimental; when disabled
(the default) sleep still releases weights/KV-cache memory as before.
**Default:** `False`

#### `--model-impl`

**Choices:** `auto`, `terratorch`, `transformers`, `vllm`

Which implementation of the model to use:

- "auto" will try to use the vLLM implementation, if it exists, and fall back to the
  Transformers implementation if no vLLM implementation is available.

- "vllm" will use the vLLM model implementation.

- "transformers" will use the Transformers model implementation.

- "terratorch" will use the TerraTorch model implementation.

**Default:** `auto`

#### `--logits-processors`

One or more logits processors' fully-qualified class names or class
definitions

#### `--io-processor-plugin`

IOProcessor plugin name to load at model startup

#### `--renderer-num-workers`

Number of worker threads in the renderer thread pool. The pool is
consumed by the async renderer path (e.g. the OpenAI-compatible API
server started by `vllm serve`) to parallelize tokenization, chat
template rendering, and multimodal preprocessing across concurrent
requests.

The offline [`LLM`](https://docs.vllm.ai/en/api/vllm/entrypoints/llm/#vllm.entrypoints.llm.LLM) entrypoint uses the synchronous renderer path and
processes prompts (including multimodal preprocessing) serially, so
this setting has no effect there.

**Default:** `1`

### LoadConfig

Configuration for loading the model weights.

#### `--load-format`

The format of the model weights to load.

- "auto" will try to load the weights in the safetensors format and fall
  back to the pytorch bin format if safetensors format is not available.

- "pt" will load the weights in the pytorch bin format.

- "safetensors" will load the weights in the safetensors format.

- "instanttensor" will load the Safetensors weights on CUDA devices using
  InstantTensor, which enables distributed loading with pipelined prefetching
  and fast direct I/O.

- "ipc_cache" will map post-quantized weights from a local weight cache
  daemon via CUDA IPC for fast engine restarts. Launch the daemon with
  `vllm preload` first.

- "npcache" will load the weights in pytorch format and store a numpy cache
  to speed up the loading.

- "dummy" will initialize the weights with random values, which is mainly
  for profiling.

- "tensorizer" will use CoreWeave's tensorizer library for fast weight
  loading. See the Tensorize vLLM Model script in the Examples section for
  more information.

- "runai_streamer" will load the Safetensors weights using Run:ai Model
  Streamer.

- "runai_streamer_sharded" will load weights from pre-sharded checkpoint
  files using Run:ai Model Streamer.

- "sharded_state" will load weights from pre-sharded checkpoint files,
  supporting efficient loading of tensor-parallel models.

- "mistral" will load weights from consolidated safetensors files used by
  Mistral models.

- "modelexpress" will load weights using ModelExpress.

- Other custom values can be supported via plugins.

**Default:** `auto`

#### `--download-dir`

Directory to download and load the weights, default to the default
cache directory of Hugging Face.

#### `--safetensors-load-strategy`

**Choices:** `eager`, [`lazy`](https://docs.vllm.ai/en/api/vllm/logging_utils/lazy/#vllm.logging_utils.lazy.lazy), `prefetch`, `torchao`, `None`

Specifies the loading strategy for safetensors weights.

- None (default): Uses memory-mapped (lazy) loading. When an NFS
  filesystem is detected and the total checkpoint size fits within 90%%
  of available RAM, prefetching is enabled automatically.

- "lazy": Weights are memory-mapped from the file. This enables
  on-demand loading and is highly efficient for models on local storage.
  Unlike the default (None), auto-prefetch on NFS is not performed.

- "eager": The entire file is read into CPU memory upfront before loading.
  This is recommended for models on network filesystems (e.g., Lustre, NFS)
  as it avoids inefficient random reads, significantly speeding up model
  initialization. However, it uses more CPU RAM.

- "prefetch": Checkpoint files are read into the OS page cache before
  workers load them, speeding up the model loading phase. Useful on
  network or high-latency storage.

- "torchao": Weights are loaded in upfront and then reconstructed
  into torchao tensor subclasses. This is used when the checkpoint
  was quantized using torchao and saved using safetensors.
  Needs `torchao >= 0.14.0`.

#### `--safetensors-prefetch-num-threads`

Number of worker threads used to prefetch safetensors checkpoint files
into the OS page cache when safetensors prefetching is enabled.
**Default:** `8`

#### `--safetensors-prefetch-block-size`

Read size in bytes for each safetensors checkpoint file prefetch.

Parse human-readable integers like '1k', '2M', etc.
    Including decimal values with decimal multipliers.

```
Examples:
- '1k' -> 1,000
- '1K' -> 1,024
- '25.6k' -> 25,600
```

**Default:** `16777216`

#### `--model-loader-extra-config`

Extra config for model loader. This will be passed to the model loader
corresponding to the chosen load_format.
**Default:** `{}`

#### `--ignore-patterns`

The list of patterns to ignore when loading the model. Default to
"original/*/" to avoid repeated loading of llama's checkpoints.
**Default:** `['original/**/*']`

#### `--use-tqdm-on-load`, `--no-use-tqdm-on-load`

Whether to enable tqdm for showing progress bar when loading model
weights.
**Default:** `True`

#### `--pt-load-map-location`

The map location for loading pytorch checkpoint, to support loading
checkpoints can only be loaded on certain devices like "cuda", this
is equivalent to `{"": "cuda"}`. Another supported format is mapping
from different devices like from GPU 1 to GPU 0: `{"cuda:1": "cuda:0"}`.
Note that when passed from command line, the strings in dictionary
need to be double quoted for json parsing. For more details, see
the original doc for `map_location` parameter in [`torch.load`](https://pytorch.org/docs/stable/generated/torch.load.html#torch.load) parameter.
**Default:** `cpu`

### AttentionConfig

Configuration for attention mechanisms in vLLM.

#### `--attention-backend`

Attention backend to use. Use "auto" or None for automatic selection.

### MambaConfig

Configuration for Mamba SSM backends.

#### `--mamba-backend`

Mamba SSU backend to use.
**Default:** `MambaBackendEnum.TRITON`

#### `--mamba-ssu-algorithm`

**Choices:** `auto`, `horizontal`, `simple`, `vertical`, `None`
Selective state update algorithm to use with the FlashInfer backend.
None defaults to FlashInfer's "auto" algorithm. Forced algorithms must
be supported by FlashInfer for the active GPU, state dtype, and decoding
mode.

#### `--enable-mamba-cache-stochastic-rounding`, `--disable-mamba-cache-stochastic-rounding`

Enable stochastic rounding when writing SSM state to fp16 cache.
Uses random bits to unbias the rounding error, which can improve
numerical stability for long sequences.
**Default:** `False`

#### `--mamba-cache-philox-rounds`

Number of Philox PRNG rounds for stochastic rounding random number
generation. 0 uses the Triton default. Higher values improve randomness
quality at the cost of compute.
**Default:** `0`

### StructuredOutputsConfig

Dataclass which contains structured outputs config for the engine.

#### `--reasoning-parser`

Select the reasoning parser depending on the model that you're using.
This is used to parse the reasoning content into OpenAI API format.

`none` disables reasoning parsing, the same as leaving it unset.

**Default:** `""`

#### `--reasoning-parser-plugin`

Path to a dynamically reasoning parser plugin that can be dynamically
loaded and registered.
**Default:** `""`

### ParallelConfig

Configuration for the distributed execution.

#### `--distributed-executor-backend`

**Choices:** `external_launcher`, `mp`, `ray`, `uni`

Backend to use for distributed model workers, either "ray" or "mp"
(multiprocessing). If the product of pipeline_parallel_size and tensor_parallel_size
is less than or equal to the number of GPUs available, "mp" will be used to
keep processing on a single host. Otherwise, an error will be raised. To use "mp"
you must also set nnodes, and to use "ray" you must manually set
distributed_executor_backend to "ray".

Note:
    [TPU](https://docs.vllm.ai/projects/tpu/en/latest/) platform only supports Ray
    for distributed inference.

#### `--pipeline-parallel-size`, `-pp`

Number of pipeline parallel groups.
**Default:** `1`

#### `--master-addr`

distributed master address for multi-node distributed
inference when distributed_executor_backend is mp.
**Default:** `127.0.0.1`

#### `--master-port`

distributed master port for multi-node distributed
inference when distributed_executor_backend is mp.
**Default:** `29501`

#### `--nnodes`, `-n`

num of nodes for multi-node distributed
inference when distributed_executor_backend is mp.
**Default:** `1`

#### `--node-rank`, `-r`

distributed node rank for multi-node distributed
inference when distributed_executor_backend is mp.
**Default:** `0`

#### `--distributed-timeout-seconds`

Timeout in seconds for distributed operations (e.g., init_process_group).
If set, this value is passed to torch.distributed.init_process_group as the
timeout parameter. If None, PyTorch's default timeout is used (600s for NCCL).
Increase this for multi-node setups where model downloads may be slow.

#### `--cpu-distributed-timeout-seconds`

Timeout (in seconds) for cpu communication groups. If None, PyTorch's
default timeout is used (1800s for gloo).

#### `--numa-bind`, `--no-numa-bind`

Enable NUMA binding for GPU worker subprocesses.

By default, workers are pinned to their GPU's NUMA-local CPUs and
memory; on PCT-capable Xeons they also auto-bind to the SKU's
PCT priority cores.

**Default:** `False`

#### `--numa-bind-nodes`

NUMA node to bind each GPU worker to.

Specify one NUMA node per visible GPU, for example `[0, 0, 1, 1]`
for a 4-GPU system with GPUs 0-1 on NUMA node 0 and GPUs 2-3 on
NUMA node 1. If unset and `numa_bind=True`, vLLM auto-detects the
GPU-to-NUMA topology. The values are passed to `numactl --membind`
and `--cpunodebind`, so they must be valid `numactl` NUMA node indices.

#### `--numa-bind-cpus`

Optional CPU lists to bind each GPU worker to.

Specify one CPU list per visible GPU, for example
`["0-3", "4-7", "8-11", "12-15"]`. When set, vLLM uses
`numactl --physcpubind` instead of `--cpunodebind`. This is useful
for custom policies such as binding to PCT or other high-frequency cores.
Each entry must use `numactl --physcpubind` CPU-list syntax, for example
`"0-3"` or `"0,2,4-7"`.

#### `--device-ids`

Comma-separated physical GPU device IDs or UUIDs to use (e.g. --device-ids "2,3,5,7"). Avoids setting CUDA_VISIBLE_DEVICES, preserving full GPU topology visibility for GPU-NIC affinity and DeepGEMM. Note: has no effect with Ray executors; use Ray placement groups for GPU selection instead.

#### `--tensor-parallel-size`, `-tp`

Number of tensor parallel groups.
**Default:** `1`

#### `--decode-context-parallel-size`, `-dcp`

Number of ranks that shard the decode KV cache. DCP does not expand
the process world size. Without PCP, DCP reuses TP ranks. With PCP, DCP
either spans the PCP axis or the full TP x PCP block.
**Default:** `1`

#### `--dcp-comm-backend`

**Choices:** `a2a`, `ag_rs`, `None`

Communication backend for Decode Context Parallel (DCP).
- "ag_rs": AllGather + ReduceScatter (existing behavior)
- "a2a": All-to-All exchange of partial outputs + LSE, then
  combine with Triton kernel. Reduces NCCL calls from 3 to 2
  per layer for MLA models.

`None` selects the model default, which is "ag_rs" unless the model
overrides it via [`set_dcp_defaults`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.ParallelConfig.set_dcp_defaults).

#### `--dcp-q-replicate`, `--no-dcp-q-replicate`

Replicate the MLA query projection within each DCP group so decode can skip the
query all-gather.

With DCP the KV cache is sharded across the group, so the standard MLA decode path
all-gathers the query every step. Replicating the (small) query projection at load
time lets each rank materialize the full group-local head set and skip that
collective, at the cost of computing the projection redundantly on every rank
in the group.

#### `--dcp-kv-cache-interleave-size`

Interleave size of kv_cache storage while using DCP.
dcp_kv_cache_interleave_size has been replaced by cp_kv_cache_interleave_size,
and will be deprecated when PCP is fully supported.
**Default:** `1`

#### `--cp-kv-cache-interleave-size`

Interleave size of kv_cache storage while using DCP.
Store interleave_size tokens on dcp_rank i, then store next
interleave_size tokens on dcp_rank i+1.
Interleave_size=1: token-level alignment, where token `i` is stored on
    dcp_rank `i % dcp_world_size`.
Interleave_size=block_size: block-level alignment, where tokens are
    first populated to the preceding ranks. Tokens are then stored
    in (rank i+1, block j) only after (rank i, block j) is fully occupied.
Block_size should be greater than or equal to cp_kv_cache_interleave_size.
Block_size should be divisible by cp_kv_cache_interleave_size.

When --cp-kv-cache-interleave-size is omitted (None), the interleave size
is resolved automatically based on NIXL transfer requirements.
Explicit settings take priority.

#### `--prefill-context-parallel-size`, `-pcp`

Number of ranks that split prefill sequence computation. PCP expands
the process world size but does not increase the KV-cache shard count.
**Default:** `1`

#### `--data-parallel-size`, `-dp`

Number of data parallel groups. MoE layers will be sharded according to
the product of the tensor, prefill-context, and data parallel sizes.
**Default:** `1`

#### `--data-parallel-rank`, `-dpn`

Data parallel rank of this instance. When set, enables external load balancer mode for MoE data-parallel deployments. Unsupported for non-MoE models; launch independent vLLM instances instead.

#### `--data-parallel-start-rank`, `-dpr`

Starting data parallel rank for secondary nodes.

#### `--data-parallel-size-local`, `-dpl`

Number of data parallel replicas to run on this node.

#### `--data-parallel-address`, `-dpa`

Address of data parallel cluster head-node.

#### `--data-parallel-rpc-port`, `-dpp`

Fixed port for data parallel RPC communication. All nodes must use the same port.

#### `--data-parallel-backend`, `-dpb`

Backend for data parallel, either "mp" or "ray".
**Default:** `mp`

#### `--data-parallel-hybrid-lb`, `--no-data-parallel-hybrid-lb`, `-dph`

Whether to use "hybrid" DP LB mode. Applies only to online serving
and when data_parallel_size > 0. Enables running an AsyncLLM
and API server on a "per-node" basis where vLLM load balances
between local data parallel ranks, but an external LB balances
between vLLM nodes/replicas. Set explicitly in conjunction with
--data-parallel-start-rank.
**Default:** `False`

#### `--data-parallel-external-lb`, `--no-data-parallel-external-lb`, `-dpe`

Whether to use "external" DP LB mode. Applies only to online serving
and when data_parallel_size > 0. This is useful for a "one-pod-per-rank"
wide-EP setup in Kubernetes. Supported only for MoE deployments; non-MoE
models should use independent vLLM instances without --data-parallel-*
arguments. Set implicitly when --data-parallel-rank is provided explicitly
to vllm serve.
**Default:** `False`

#### `--data-parallel-multi-port-external-lb`, `-dpm`

Run a node-local supervisor that launches one external-LB API server per local data parallel rank and exposes aggregated health on a supervisor port.
**Default:** `False`

#### `--enable-hc-sp`, `--disable-hc-sp`

Enable sequence parallelism for HyperConnection (HC) computation.
Currently supported by Qwen4Exp on CUDA/ROCm with TP>1 and PP=1 (ignored when TP=1).
Does not change MoE parallelism. MoE SP may enable HC SP independently of this flag.
**Default:** `False`

#### `--enable-expert-parallel`, `-ep`, `--disable-expert-parallel`

Use expert parallelism instead of tensor parallelism for MoE layers.
**Default:** `False`

#### `--enable-batch-sharded-sampling`, `--disable-batch-sharded-sampling`

Use sharded sampling across tensor parallel ranks. Each rank samples
a slice of the batch instead of every rank sampling all of it. Currently
defaults to False if not set. Enabling it explicitly raises when the config
cannot support it (`tensor_parallel_size` must be > 1, `max_num_seqs` at
least `tensor_parallel_size`, and `max_logprobs` non-negative). Models opt in
by implementing `compute_logits_local`.

#### `--enable-ep-weight-filter`, `--disable-ep-weight-filter`

Skip non-local expert weights during model loading when expert
parallelism is active.  Each rank only reads its own expert shard from
disk, which can drastically reduce storage I/O for MoE models with
per-expert weight tensors (e.g. DeepSeek, Mixtral, Kimi-K2.5).  Has no
effect on 3D fused-expert checkpoints (e.g. GPT-OSS) or non-MoE
models.
**Default:** `False`

#### `--all2all-backend`

**Choices:** `allgather_reducescatter`, `deepep_high_throughput`, `deepep_low_latency`, `deepep_v2`, `flashinfer_all2allv`, `flashinfer_nvlink_one_sided`, `flashinfer_nvlink_two_sided`, `moonep`, `mori_high_throughput`, `mori_low_latency`, `naive`, `nixl_ep`, `pplx`

All2All backend for MoE expert parallel communication. Available options:

- "allgather_reducescatter": All2all based on allgather and reducescatter

- "deepep_high_throughput": Use deepep high-throughput kernels

- "deepep_low_latency": Use deepep low-latency kernels

- "mori_high_throughput": MoRI EP with InterNodeV1 for multi-node

- "mori_low_latency": MoRI EP with InterNodeV1LL for multi-node

- "moonep": MoonEP balanced EP with dynamic redundant experts (NVLink)

- "nixl_ep": Use nixl-ep kernels

- "flashinfer_nvlink_one_sided": Use flashinfer high-throughput a2a kernels

- "flashinfer_nvlink_two_sided": Use flashinfer two-sided kernels for mnnvl

- "passthrough": No all2all at all: the MoE backend dispatches and combines
  itself (e.g. the FlashInfer MoE-EP megakernels). Bound automatically for
  such MoE backends; not selectable from the CLI.

**Default:** `allgather_reducescatter`

#### `--enable-dbo`, `--disable-dbo`

Enable dual batch overlap for the model executor.
**Default:** `False`

#### `--enable-shm-tensor-arena`, `--disable-shm-tensor-arena`

Route large CPU tensors (e.g. multimodal `pixel_values`) in the
engine→worker broadcast through a zero-copy shared-memory arena instead of
sending a copy to every reader. Experimental: may be reconciled with
vLLM's existing multimodal shm tensor caching in a future release. Opt-in;
most beneficial for multimodal serving with large images and tensor
parallelism. Active only when all queue readers are node-local; reserves
slots in `/dev/shm`.
**Default:** `False`

#### `--ubatch-size`

Number of ubatch size.
**Default:** `0`

#### `--enable-elastic-ep`, `--disable-elastic-ep`

Enable elastic expert parallelism with stateless NCCL groups for DP/EP.
**Default:** `False`

#### `--elastic-ep-max-dp-size`

Maximum data parallel size supported by elastic expert parallelism.

#### `--dbo-decode-token-threshold`

The threshold for dual batch overlap for batches only containing decodes.
If the number of tokens in the request is greater than this threshold,
microbatching will be used. Otherwise, the request will be processed in a
single batch.
**Default:** `32`

#### `--dp-sync-interval`

Steps between DP finish-sync all-reduces; must match across DP ranks.
**Default:** `16`

#### `--dbo-prefill-token-threshold`

The threshold for dual batch overlap for batches that contain one or more
prefills. If the number of tokens in the request is greater than this
threshold, microbatching will be used. Otherwise, the request will be
processed in a single batch.
**Default:** `512`

#### `--disable-nccl-for-dp-synchronization`, `--enable-nccl-for-dp-synchronization`

Forces the dp synchronization logic in vllm/v1/worker/dp_utils.py
to use Gloo instead of NCCL for its all reduce.

Defaults to True when async scheduling is enabled, False otherwise.

#### `--enable-eplb`, `--disable-eplb`

Enable expert parallelism load balancing for MoE layers.
**Default:** `False`

#### `--eplb-config`

Expert parallelism configuration.

API docs: [`vllm.config.EPLBConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.EPLBConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `EPLBConfig(window_size=1000, step_interval=3000, num_redundant_experts=0, log_balancedness=False, log_balancedness_interval=1, use_async=True, policy='default', communicator=None, enable_migration_batching=False)`

#### `--expert-placement-strategy`

**Choices:** `linear`, `round_robin`

The expert placement strategy for MoE layers:

- "linear": Experts are placed in a contiguous manner. For example, with 4
  experts and 2 ranks, rank 0 will have experts [0, 1] and rank 1 will have
  experts [2, 3].

- "round_robin": Experts are placed in a round-robin manner. For example,
  with 4 experts and 2 ranks, rank 0 will have experts [0, 2] and rank 1
  will have experts [1, 3]. This strategy can help improve load balancing
  for grouped expert models with no redundant experts.

**Default:** `linear`

#### `--max-parallel-loading-workers`

Maximum number of parallel loading workers when loading model
sequentially in multiple batches. To avoid RAM OOM when using tensor
parallel and large models.

#### `--ray-workers-use-nsight`, `--no-ray-workers-use-nsight`

Whether to profile Ray workers with nsight, see https://docs.ray.io/en/latest/ray-observability/user-guides/profiling.html#profiling-nsight-profiler.
**Default:** `False`

#### `--disable-custom-all-reduce`, `--enable-custom-all-reduce`

Disable the custom all-reduce kernel and fall back to NCCL.
**Default:** `False`

#### `--worker-cls`

The full name of the worker class to use. If "auto", the worker class
will be determined based on the platform.
**Default:** `auto`

#### `--worker-extension-cls`

The full name of the worker extension class to use. The worker extension
class is dynamically inherited by the worker class. This is used to inject
new attributes and methods to the worker class for use in collective_rpc
calls. It may also define `init_worker_extension(self)`, called after
device and distributed initialization but before model loading, and
`destroy_worker_extension(self)`, called (best-effort) before the worker
shuts down.
**Default:** `""`

#### `--enable-fault-tolerance`, `--disable-fault-tolerance`

Enable fault tolerance for detailed error recovery,
such as scaling down fault DPEngineCore.
**Default:** `False`

#### `--fault-tolerance-config`

The configurations for fault tolerance.

API docs: [`vllm.config.FaultToleranceConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.FaultToleranceConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `FaultToleranceConfig(engine_recovery_timeout_sec=120)`

### CacheConfig

Configuration for the KV cache.

#### `--block-size`

Size of a contiguous cache block in number of tokens.
Accepts None (meaning "use default"). After construction, always int.

#### `--gpu-memory-utilization`, `--device-memory-utilization`

The fraction of GPU memory to be used for the model executor, which can
range from 0 to 1. For example, a value of 0.5 would imply 50% GPU memory
utilization. If unspecified, will use the default value of 0.92. This is a
per-instance limit, and only applies to the current vLLM instance. It does
not matter if you have another vLLM instance running on the same GPU. For
example, if you have two vLLM instances running on the same GPU, you can
set the GPU memory utilization to 0.5 for each instance. On non-GPU
installs, this value controls the corresponding device memory utilization.
**Default:** `0.92`

#### `--kv-cache-memory-bytes`

Size of KV Cache per GPU in bytes. By default, this is set to None
and vllm can automatically infer the kv cache size based on
gpu_memory_utilization. However, users may want to manually specify
the kv cache memory size. kv_cache_memory_bytes allows more fine-grain
control of how much memory gets used when compared with using
gpu_memory_utilization. Note that kv_cache_memory_bytes
(when not-None) ignores gpu_memory_utilization

Parse human-readable integers like '1k', '2M', etc.
    Including decimal values with decimal multipliers.

```
Examples:
- '1k' -> 1,000
- '1K' -> 1,024
- '25.6k' -> 25,600
```

#### `--kv-cache-dtype`

**Choices:** `auto`, `bfloat16`, `float16`, `fp8`, `fp8_ds_mla`, `fp8_e4m3`, `fp8_e5m2`, `fp8_inc`, `fp8_per_token_head`, `int4_per_token_head`, `int8_per_token_head`, `nvfp4`, `nvfp4_4over6`, `nvfp4_ds_mla`, `octave_k3v3`, `octave_k3v3_compact`, `octave_k3v4`, `turboquant_3bit_nc`, `turboquant_4bit_nc`, `turboquant_k3v4_nc`, `turboquant_k8v4`, `ultraquant_4bit`
Data type for kv cache storage. If "auto", will use model data type.
An explicit float16 or bfloat16 must match the model data type.
Custom dtypes can registered by platform backends via
`register_kv_cache_dtype` are accepted (see vllm.config.cache).
CUDA 11.8+ supports fp8 (=fp8_e4m3) and fp8_e5m2. ROCm (AMD GPU) supports
fp8 (=fp8_e4m3). Intel Gaudi (HPU) supports fp8 (using fp8_inc).
Some models (namely DeepSeekV3.2) default to fp8, set to bfloat16 to use
bfloat16 instead, this is an invalid option for models that do not default
to fp8.
"nvfp4_4over6" uses the NVFP4 layout and selects between max/6 and max/4
scales per 16 values by minimizing squared reconstruction error.
**Default:** `auto`

#### `--num-gpu-blocks-override`

Number of GPU blocks to use. This overrides the profiled `num_gpu_blocks`
if specified. Does nothing if `None`. Used for testing preemption.

#### `--enable-prefix-caching`, `--disable-prefix-caching`

Whether to enable prefix caching.

#### `--prefix-caching-hash-algo`

**Choices:** `sha256`, `sha256_cbor`, `xxhash`, `xxhash_cbor`

Set the hash algorithm for prefix caching:

- "sha256" uses Pickle for object serialization before hashing. This is the current
  default, as SHA256 is the most secure choice to avoid potential hash collisions.

- "sha256_cbor" provides a reproducible, cross-language compatible hash. It
  serializes objects using canonical CBOR and hashes them with SHA-256.

- "xxhash" uses Pickle serialization with xxHash (128-bit) for faster,
  non-cryptographic hashing. Requires the optional `xxhash` package.
  IMPORTANT: Use of a hashing algorithm that is not considered  cryptographically
  secure theoretically increases the risk of hash collisions, which can cause
  undefined behavior or even leak private information in multi-tenant environments.
  Even if collisions are still very unlikely, it is important to consider your
  security risk tolerance against the performance benefits before turning this on.

- "xxhash_cbor" combines canonical CBOR serialization with xxHash for
  reproducible hashing. Requires the optional `xxhash` package.

**Default:** `sha256`

#### `--prefix-cache-retention-interval`

Token interval between retained sliding-window and Mamba prefix-cache
checkpoints. `0` retains only semantic checkpoints, including the latest
replay boundary and shared-prefix junctions. Positive values additionally
retain periodic checkpoints at the specified interval, which must be a
multiple of the scheduler block size. `None` retains checkpoints densely.
Applies only to sliding-window and Mamba cache groups.
**Default:** `0`

#### `--kv-cache-dtype-skip-layers`

Layer patterns to skip KV cache quantization. Accepts layer indices
(e.g., '0', '2', '4') or attention type names (e.g., 'sliding_window').
**Default:** `[]`

#### `--kv-sharing-fast-prefill`, `--no-kv-sharing-fast-prefill`

In some KV sharing setups, e.g. YOCO (https://arxiv.org/abs/2405.05254),
some layers can skip tokens corresponding to prefill. This flag enables
attention metadata for eligible layers to be overridden with metadata
necessary for implementing this optimization in some models (e.g. Gemma3n)
**Default:** `False`

#### `--swa-bounded-replay`, `--no-swa-bounded-replay`

Keep the sliding-window KV of models that support it (DeepSeek-V4.1)
out of prefix caching and rebuild it after a prefix hit by recomputing the
hit's last window. The layers past the last KV-source layer then also run
eager prefill steps on each request's trailing window only. Requires model
runner V2.
**Default:** `True`

#### `--mamba-cache-dtype`

**Choices:** `auto`, `bfloat16`, `float16`, `float32`
The data type to use for the Mamba cache (both the conv as well as the
ssm state). If set to 'auto', the data type will be inferred from the model
config.
**Default:** `auto`

#### `--mamba-ssm-cache-dtype`

**Choices:** `auto`, `bfloat16`, `float16`, `float32`
The data type to use for the Mamba cache (ssm state only, conv state will
still be controlled by mamba_cache_dtype). If set to 'auto', the data type
for the ssm state will be determined by mamba_cache_dtype.
**Default:** `auto`

#### `--mamba-block-size`

Size of a contiguous cache block in number of tokens for mamba cache.
Can be set only when prefix caching is enabled.

#### `--prefix-match-unit`

The finest token boundary (in tokens) a prefix-cache hit can land on.

Prefix-cache keys are computed every `prefix_match_unit` tokens. It can
be set finer than the physical KV cache block sizes (e.g. 32 vs a
1024-token hybrid-model block) as long as every KV cache group's
`block_size` is divisible by it, enabling cache hits at boundaries
inside a physical block. It controls matching granularity only, not how
often states are stored.

This equals to the `hash_block_size` used throughout the KV cache code.

#### `--mamba-cache-mode`

**Choices:** `align`, `none`
--mamba-cache-mode is deprecated and will be removed in v0.33.0. It has no effect: Mamba prefix caching follows --enable-prefix-caching.

#### `--enable-mamba-shared-prefix-checkpoint`, `--disable-mamba-shared-prefix-checkpoint`

Also register a Mamba "align" checkpoint at the shared-prefix junction --
where an EAGLE/MTP sibling was observed to resume -- instead of only at the
prompt tail. Off by default; only takes effect with prefix caching enabled,
EAGLE on the Mamba group, and a prefix match unit smaller than the Mamba
block size.
**Default:** `False`

#### `--replayssm-buffer-len`

ReplaySSM logical history length B for Mamba2. Triton uses B physical
rows and FlashInfer uses B+T, where T is the target verification length.
Kimi-K3 speculative decode does not use B. Default 16.
**Default:** `16`

#### `--use-replayssm`, `--no-use-replayssm`

Use the ReplaySSM Mamba2 decode kernel: cache recent SSM inputs and skip
the per-step full-state store, writing the checkpoint back only on flush.
Requires the Triton or FlashInfer mamba backend; FlashInfer does not support
prefix caching yet. Mamba2 speculative decode requires FlashInfer. With
prefix caching, flushes are most efficient when mamba_block_size is a
multiple of replayssm_buffer_len, but this is not required.
**Default:** `False`

#### `--kv-offloading-size`

Size of the KV cache offloading buffer in GiB. When TP > 1, this is
the total buffer size summed across all TP ranks. By default, this is set
to None, which means no KV offloading is enabled. When set, vLLM will
enable KV cache offloading to CPU using the kv_offloading_backend.

#### `--kv-offloading-backend`

**Choices:** `lmcache`, `native`
The backend to use for KV cache offloading. Supported backends include
'native' (vLLM native CPU offloading), 'lmcache'.
KV offloading is only activated when kv_offloading_size is set.
**Default:** `native`

### OffloadConfig

Configuration for model weight offloading to reduce GPU memory usage.

#### `--offload-backend`

**Choices:** `auto`, `prefetch`, `uva`
The backend for weight offloading. Options:
- "auto": Selects based on which sub-config has non-default values
  (prefetch if offload_group_size > 0, uva if cpu_offload_gb > 0).
- "uva": UVA (Unified Virtual Addressing) zero-copy offloading.
- "prefetch": Async prefetch with group-based layer offloading.
**Default:** `auto`

#### `--cpu-offload-gb`

The space in GiB to offload to CPU, per GPU. Default is 0, which means
no offloading. Intuitively, this argument can be seen as a virtual way to
increase the GPU memory size. For example, if you have one 24 GB GPU and
set this to 10, virtually you can think of it as a 34 GB GPU. Then you can
load a 13B model with BF16 weight, which requires at least 26GB GPU memory.
Note that this requires fast CPU-GPU interconnect, as part of the model is
loaded from CPU memory to GPU memory on the fly in each model forward pass.
This uses UVA (Unified Virtual Addressing) for zero-copy access.
**Default:** `0`

#### `--cpu-offload-params`

The set of parameter name segments to target for CPU offloading.
Unmatched parameters are not offloaded. If this set is empty, parameters
are offloaded non-selectively until the memory limit defined by
`cpu_offload_gb` is reached.
Examples:
    - For parameter name "mlp.experts.w2_weight":
        - "experts" or "experts.w2_weight" will match.
        - "expert" or "w2" will NOT match (must be exact segments).
This allows distinguishing parameters like "w2_weight" and "w2_weight_scale".
**Default:** `set()`

#### `--offload-group-size`

Group every N layers together. Offload last `offload_num_in_group`
layers of each group. Default is 0 (disabled).
Example: group_size=8, num_in_group=2 offloads layers 6,7,14,15,22,23,...
Unlike cpu_offload_gb, this uses explicit async prefetching to hide transfer
latency.
**Default:** `0`

#### `--offload-num-in-group`

Number of layers to offload per group.
Must be <= offload_group_size. Default is 1.
**Default:** `1`

#### `--offload-prefetch-step`

Number of layers to prefetch ahead.
Higher values hide more latency but use more GPU memory. Default is 1.
**Default:** `1`

#### `--offload-params`

The set of parameter name segments to target for prefetch offloading.
Unmatched parameters are not offloaded. If this set is empty, ALL
parameters of each offloaded layer are offloaded.
Uses segment matching: "w13_weight" matches "mlp.experts.w13_weight"
but not "mlp.experts.w13_weight_scale".
**Default:** `set()`

### MultiModalConfig

Controls the behavior of multimodal models.

#### `--language-model-only`, `--no-language-model-only`

If True, disables all multimodal inputs by setting all modality limits to 0.
Equivalent to setting `--limit-mm-per-prompt` to 0 for every modality.
**Default:** `False`

#### `--limit-mm-per-prompt`

The maximum number of input items and options allowed per
prompt for each modality.

Defaults to 999 for each modality.

Legacy format (count only):

Configurable format (with options):
    {"video": {"count": 1, "num_frames": 32, "width": 512, "height": 512},
    "image": {"count": 5, "width": 512, "height": 512}}

Mixed format (combining both):
    {"image": 16, "video": {"count": 1, "num_frames": 32, "width": 512,
    "height": 512}}

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `{}`

#### `--enable-mm-embeds`, `--disable-mm-embeds`

If `True`, enables passing multimodal embeddings:
for [`LLM`](https://docs.vllm.ai/en/api/vllm/entrypoints/llm/#vllm.entrypoints.llm.LLM) class, this refers to tensor inputs under `multi_modal_data`;
for the OpenAI-compatible server, this refers to chat messages with content
`"type": "*_embeds"`.

When enabled with `--limit-mm-per-prompt` set to 0 for a modality,
precomputed embeddings skip count validation for that modality,
saving memory by not loading encoder modules while still enabling
embeddings as an input. Limits greater than 0 still apply to embeddings.

WARNING: The vLLM engine may crash if incorrect shape of embeddings is passed.
Only enable this flag for trusted users!

**Default:** `False`

#### `--media-io-kwargs`

Additional args passed to process media inputs, keyed by modalities.
For example, to set num_frames for video, set
`--media-io-kwargs '{"video": {"num_frames": 40} }'`

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `{}`

#### `--mm-processor-kwargs`

Arguments to be forwarded to the model's processor for multi-modal data,
e.g., image processor. Overrides for the multi-modal processor obtained
from `transformers.AutoProcessor.from_pretrained`.

The available overrides depend on the model that is being run.

For example, for Phi-3-Vision:
`{"num_crops": 4}`.

Should either be a valid JSON string or JSON keys passed individually.

#### `--mm-processor-cache-gb`

The size (in GiB) of the multi-modal processor cache, which is used to
avoid re-processing past multi-modal inputs.

This cache is duplicated for each API process and engine core process,
resulting in a total memory usage of
`mm_processor_cache_gb * (api_server_count + data_parallel_size)`.

A single processed item larger than this budget is served uncached
(with a warning) instead of failing. Raise this value to cache such items.

Set to `0` to disable this cache completely (not recommended).

**Default:** `4`

#### `--mm-processor-cache-type`

**Choices:** `lru`, `shm`
Type of cache to use for the multi-modal preprocessor/mapper. If `shm`,
use shared memory FIFO cache. If `lru`, use mirrored LRU cache.
**Default:** `lru`

#### `--mm-hasher-algorithm`

**Choices:** `blake3`, `sha256`, `sha512`
Hash algorithm to use for multi-modal input caching. Use `"sha256"` or
`"sha512"` for FIPS-compliant deployments.
**Default:** `blake3`

#### `--mm-shm-cache-max-object-size-mb`

Size limit (in MiB) for each object stored in the multi-modal processor
shared memory cache. Only effective when `mm_processor_cache_type` is
`"shm"`.
**Default:** `128`

#### `--mm-encoder-only`, `--no-mm-encoder-only`

When enabled, skips the language component of the model.

This is usually only valid in disaggregated Encoder process.

**Default:** `False`

#### `--mm-encoder-tp-mode`

**Choices:** `data`, `weights`

Indicates how to optimize multi-modal encoder inference using tensor
parallelism (TP).

- `"weights"`: Within the same vLLM engine, split the weights of
  each layer across TP ranks. (default TP behavior)

- `"data"`: Within the same vLLM engine, split the batched input data
  across TP ranks to process the data in parallel, while hosting
  the full weights on each TP rank.
  This batch-level DP is not to be confused with API request-level
  DP (which is controlled by `--data-parallel-size`).
  This is only supported on a per-model basis and falls back to
  `"weights"` if the encoder does not support DP.

**Default:** `weights`

#### `--mm-encoder-attn-backend`

Optional override for the multi-modal encoder attention backend when
using vision transformers. Accepts any value from
`vllm.v1.attention.backends.registry.AttentionBackendEnum` (e.g. `FLASH_ATTN`).

#### `--mm-encoder-attn-dtype`

**Choices:** `fp8`, `None`
Optional dtype override for ViT encoder attention. Set to `"fp8"` to
enable FP8 quantization via the FlashInfer cuDNN backend. When set to
`"fp8"` without a scale file, dynamic scaling is used automatically.
See docs/features/quantization/fp8_vit_attn.md for details.

#### `--mm-encoder-fp8-scale-path`

Path to a JSON file containing per-layer FP8 Q/K/V scales for ViT
encoder attention. When provided (with `mm_encoder_attn_dtype="fp8"`),
static scaling is used. When omitted, dynamic scaling is used.

#### `--mm-encoder-fp8-scale-save-path`

When set with dynamic FP8 scaling (`mm_encoder_attn_dtype="fp8"`
and no `mm_encoder_fp8_scale_path`), saves the calibrated scales to
this file after the amax history buffer is full. The saved file can
then be used as `mm_encoder_fp8_scale_path` in subsequent runs.

#### `--mm-encoder-fp8-scale-save-margin`

Safety margin multiplied onto scales when auto-saving. A value > 1
leaves headroom so that inputs with larger activations than the
calibration set do not overflow FP8 range. Default 1.5.
**Default:** `1.5`

#### `--interleave-mm-strings`, `--no-interleave-mm-strings`

Enable fully interleaved support for multimodal prompts, while using
--chat-template-content-format=string.
**Default:** `False`

#### `--skip-mm-profiling`, `--no-skip-mm-profiling`

When enabled, skips multimodal memory profiling and only profiles with
language backbone model during engine initialization.

This reduces engine startup time but shifts the responsibility to users for
estimating the peak memory usage of the activation of multimodal encoder and
embedding cache.

**Default:** `False`

#### `--video-pruning-rate`

Fraction of video tokens to prune from each video. Value sits in range
[0;1); pruning is enabled when it is greater than 0. The pruning algorithm
is selected by `video_pruning_method`.

#### `--video-pruning-method`

**Choices:** `evs`, `vidcom2`
Video token pruning algorithm applied when `video_pruning_rate` > 0:
- "evs": Efficient Video Sampling.
- "vidcom2": Video Compression Commander.
**Default:** `evs`

#### `--mm-tensor-ipc`

**Choices:** `direct_rpc`, `torch_shm`
IPC (inter-process communication) method for multimodal tensors.
- "direct_rpc": Use msgspec serialization via RPC
- "torch_shm": Use torch.multiprocessing shared memory for zero-copy IPC
Defaults to "direct_rpc".
**Default:** `direct_rpc`

#### `--mm-processor-device`

**Choices:** `auto`, `cpu`

Device the HF multi-modal processor runs the image/video transform on. Convenience for `--mm-processor-kwargs '{"device": ...}'`: the value is resolved here and stored there, it is not kept as separate state. Only takes effect for HF "fast" (torchvision-backed) processors, which accept a `device` argument; the others ignore it and stay on CPU.

"auto" uses the accelerator on encoder instances of an encode/prefill/decode deployment -- an EC producer that is not also a consumer allocates no KV cache, so its accelerator is not contended by the language model -- and then only when `--mm-tensor-ipc=torch_shm` can carry device tensors, since every other transport would copy the result back to the host and that copy costs more than it saves. "auto" resolves to "cpu" everywhere else.

**Default:** `auto`

#### `--mm-ipc-gpu-memory-gb`

Amount of GPU memory (in GiB) sequestered on the engine's device for
GPU-side multimodal work in the API-server (frontend) process, such as
hardware video decoding.

This budget is carved out of the engine's KV-cache memory so the headroom
physically exists, and frontend GPU decode paths acquire from a blocking
byte-counting semaphore of this size before allocating on the device.

Set to `0` (default) to disable frontend GPU multimodal memory gating.

**Default:** `0`

#### `--mm-device-do-normalize`, `--no-mm-device-do-normalize`

Move the do_normalize computation in the mm preprocessing to before the ViT,
and let the device do it, so that CPU computation can be saved.

### LoRAConfig

Configuration for LoRA.

#### `--enable-lora`, `--disable-lora`

If True, enable handling of LoRA adapters.

#### `--max-loras`

Max number of LoRAs in a single batch.
**Default:** `1`

#### `--max-lora-rank`

**Choices:** `1`, `8`, `16`, `32`, `64`, `128`, `256`, `320`, `512`
Max LoRA rank.
**Default:** `16`

#### `--lora-dtype`

Data type for LoRA. If auto, will default to base model dtype.
**Default:** `auto`

#### `--enable-tower-connector-lora`, `--disable-tower-connector-lora`

If `True`, LoRA support for the tower (vision encoder) and connector
of multimodal models will be enabled. This is an experimental feature and
currently only supports some MM models such as the Qwen VL series. The default
is False.
**Default:** `False`

#### `--max-cpu-loras`

Maximum number of LoRAs to store in CPU memory. Must be >= than
`max_loras`.

#### `--fully-sharded-loras`, `--no-fully-sharded-loras`

By default, only half of the LoRA computation is sharded with tensor
parallelism. Enabling this will use the fully sharded layers. At high
sequence length, max rank or tensor parallel size, this is likely faster.
**Default:** `False`

#### `--lora-target-modules`

Restrict LoRA to specific module suffixes (e.g., ["o_proj", "qkv_proj"]).
If None, all supported LoRA modules are used. This allows deployment-time
control over which modules have LoRA applied, useful for performance tuning.

#### `--default-mm-loras`

Dictionary mapping specific modalities to LoRA model paths; this field
is only applicable to multimodal models and should be leveraged when a
model always expects a LoRA to be active when a given modality is present.
Note that currently, if a request provides multiple additional
modalities, each of which have their own LoRA, we do NOT apply
default_mm_loras because we currently only support one lora adapter
per prompt. When run in offline mode, the lora IDs for n modalities
will be automatically assigned to 1-n with the names of the modalities
in alphabetic order.

Should either be a valid JSON string or JSON keys passed individually.

#### `--specialize-active-lora`, `--no-specialize-active-lora`

Whether to construct lora kernel grid by the number of active LoRA adapters.
When set to True, separate cuda graphs will be captured for different counts
of active LoRAs (powers of 2 up to max_loras), which can improve performance
for variable LoRA usage patterns at the cost of increased startup time and
memory usage. Only takes effect when cudagraph_specialize_lora is True.
**Default:** `False`

#### `--enable-mixed-moe-lora-format`, `--disable-mixed-moe-lora-format`

If True, force the engine to use the universal 2D MoE LoRA wrapper
(`FusedMoEWithLoRA`) regardless of the model's `is_3d_moe_weight` flag, so
that 2D-format and 3D-format MoE LoRA adapters can be served in the same
deployment. Only meaningful for MoE models; ignored otherwise. Default False
keeps the existing model-driven behavior.
**Default:** `False`

#### `--enable-moe-shared-loras`, `--disable-moe-shared-loras`

If True, load MoE expert adapters in the "shared-outer" layout, where the
gate/up (`w1`/`w3`) lora_A and the down (`w2`) lora_B are shared across all
experts (stored once with expert-dim 1) instead of per-expert. The shared
factors are broadcast to the expert count at kernel time. 3D-weight MoE
models use `FusedMoEWithLoRA` for this layout. Only meaningful for MoE
models whose adapters use this layout; ignored otherwise.
**Default:** `False`

#### `--max-lora-cls-labels`

Maximum output size for LoRA classification heads. Defaults to the
base classification head size.

### LoggingConfig

vLLM logging. Default `dictConfig` adds a formatted stream handler.

Supply a JSON object with `--logging-config` or individual fields with
dotted arguments such as `--logging-config.log_level DEBUG` and
`--logging-config.formatter json`. `--log-level` and legacy
`--log-config-file` override their matching fields. Set
`configure_logging` to false to skip applying a `dictConfig`.

#### `--logging-config`

Logging configuration.

API docs: [`vllm.config.LoggingConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.LoggingConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--log-level`

**Choices:** `CRITICAL`, `ERROR`, `WARNING`, `INFO`, `DEBUG`, `NOTSET`
Shortcut for --logging-config.log_level. Overrides that field if both are specified.

#### `--log-config-file`

--log-config-file is deprecated and will be removed in v0.33.0. Use --logging-config.pylogging_config_file instead.

### ObservabilityConfig

Configuration for observability - metrics and tracing.

#### `--show-hidden-metrics-for-version`

Enable deprecated Prometheus metrics that have been hidden since the
specified version. For example, if a previously deprecated metric has been
hidden since the v0.7.0 release, you use
`--show-hidden-metrics-for-version=0.7` as a temporary escape hatch while
you migrate to new metrics. The metric is likely to be removed completely
in an upcoming release.

#### `--otlp-traces-endpoint`

Target URL to which OpenTelemetry traces will be sent.

#### `--collect-detailed-traces`

**Choices:** `all`, `model`, `worker`, `None`

It makes sense to set this only if `--otlp-traces-endpoint` is set. If
set, it will collect detailed traces for the specified modules. This
involves use of possibly costly and or blocking operations and hence might
have a performance impact.

Note that collecting detailed timing information for each request can be
expensive.

#### `--per-request-spec-decode-metrics`

**Choices:** `detailed`, `none`, `summary`
Include per-request speculative-decoding acceptance metrics in the
response under `metrics.speculative_decoding`. `none` disables; `summary` adds mean
acceptance length, draft acceptance rate, and the step-by-draft-length
histogram; `detailed` additionally records the ordered per-step
accepted/proposed arrays (one entry per verify step). Only reported for
single-sequence requests (`n == 1`), mirroring the timing metrics. No effect
unless speculative decoding is enabled. Independent of `--disable-log-stats`.
This is the per-request response-body counterpart of the aggregate
`vllm:spec_decode_*` Prometheus metrics. The response field is experimental
and its shape may change in a future release.
**Default:** `none`

#### `--kv-cache-metrics`, `--no-kv-cache-metrics`

Enable KV cache residency metrics (lifetime, idle time, reuse gaps).
Uses sampling to minimize overhead.
Requires log stats to be enabled (i.e., --disable-log-stats not set).
**Default:** `False`

#### `--kv-cache-metrics-sample`

Sampling rate for KV cache metrics (0.0, 1.0]. Default 0.01 = 1% of blocks.
**Default:** `0.01`

#### `--custom-histogram-buckets`

Custom Prometheus histogram bucket boundaries, as a JSON mapping from
bucket-family key to a list of strictly increasing, positive, finite
upper bounds. When a family key is present, its list replaces the default
buckets for every histogram in that family; families not listed keep
their defaults. Known families: `request_latency`, `time_to_first_token`,
`inter_token_latency`, `iteration_tokens`, `request_params_n`,
`request_num_preemptions`, `request_tokens`, `kv_cache_residency`. Example:
`--custom-histogram-buckets '{"request_latency": [0.01, 0.05, 0.1, 0.5]}'`.
Note that every extra bucket adds one time series per metric and label
set.

Should either be a valid JSON string or JSON keys passed individually.

#### `--cudagraph-metrics`, `--no-cudagraph-metrics`

Enable CUDA graph metrics (number of padded/unpadded tokens, runtime cudagraph
dispatch modes, and their observed frequencies at every logging interval).
**Default:** `False`

#### `--enable-layerwise-nvtx-tracing`, `--disable-layerwise-nvtx-tracing`

Enable layerwise NVTX tracing. This traces the execution of each layer or
module in the model and attach information such as input/output shapes to
nvtx range markers. Noted that this doesn't work with CUDA graphs enabled.
**Default:** `False`

#### `--enable-mfu-metrics`, `--disable-mfu-metrics`

Enable Model FLOPs Utilization (MFU) metrics.
**Default:** `False`

#### `--enable-logging-iteration-details`, `--disable-logging-iteration-details`

Enable detailed logging of iteration details.
If set, vllm EngineCore will log iteration details
This includes number of context/generation requests and tokens
and the elapsed cpu time for the iteration.
**Default:** `False`

#### `--jit-monitor-mode`

**Choices:** `error`, `warn`
How to handle post-warmup JIT compilation events.
**Default:** `warn`

#### `--jit-monitor-verbose`, `--no-jit-monitor-verbose`

Log every monitored JIT compile with runtime details. This can emit many
logs and add overhead, so it is intended for debugging.
**Default:** `False`

### SchedulerConfig

Scheduler configuration.

#### `--max-num-batched-tokens`

Maximum number of tokens that can be processed in a single iteration.

The default value here is mainly for convenience when testing.
In real usage, this should be set in `EngineArgs.create_engine_config`.

Parse human-readable integers like '1k', '2M', etc.
    Including decimal values with decimal multipliers.

```
Examples:
- '1k' -> 1,000
- '1K' -> 1,024
- '25.6k' -> 25,600
```

#### `--max-num-scheduled-tokens`

Maximum number of tokens that the scheduler may issue in a single iteration.

This is usually equal to max_num_batched_tokens, but can be smaller in cases
when the model might append tokens into the batch (such as speculative decoding).
Defaults to max_num_batched_tokens.

Parse human-readable integers like '1k', '2M', etc.
    Including decimal values with decimal multipliers.

```
Examples:
- '1k' -> 1,000
- '1K' -> 1,024
- '25.6k' -> 25,600
```

#### `--max-num-seqs`

Maximum number of sequences to be processed in a single iteration.

The default value here is mainly for convenience when testing.
In real usage, this should be set in `EngineArgs.create_engine_config`.

#### `--max-num-active-seqs`

Maximum number of requests the scheduler admits into RUNNING.

`max_num_seqs` sizes the model runner (per-request buffers and CUDA
graph capture) and is also the default admission limit. Setting this
lowers only the number of requests that may occupy RUNNING, so decode
batches stay smaller without shrinking runner or graph capacity. Must
be `<= max_num_seqs`. `None` (default) keeps current behavior.

#### `--max-num-queued-reqs`

Maximum number of requests that can be in-flight (waiting or running)
at the same time, or None for no limit. When the limit is reached, new
requests are rejected with HTTP 503 so the client can retry on another
instance. This bounds vLLM's otherwise unbounded request queue and is
primarily a coarse capacity valve.

Unlike `max_num_seqs`, which applies per data-parallel rank, this
limit is enforced in the API server process and counts in-flight
requests across all DP ranks it routes to. Size it as roughly
`data_parallel_size * max_num_seqs` plus the desired queue depth if
it should not bind before per-rank admission does.

#### `--max-num-queued-tokens`

Maximum total prompt tokens of requests currently in the prefill
phase, or None for no limit. When the limit is reached, new requests
are rejected with HTTP 503.

This is a TTFT QoS mechanism: by setting it to
`target_TTFT * prefill_throughput` you reject requests when the
prefill backlog would exceed the latency target.  In a disaggregated
prefill-decode setup this maps directly to the prefill pool's
capacity.

Like `max_num_queued_reqs`, this limit is enforced in the API
server process and covers the prefill backlog across all DP ranks it
routes to, so `prefill_throughput` in the formula above is the
aggregate throughput of the deployment.

Note: the count is conservative.  A partially prefilled request
still contributes its full `prompt_len` until it transitions out
of the prefill phase, because the scheduler's per-iteration
`num_computed_tokens` progress is not propagated to the API
server process during prefill (`EngineCoreOutput` is only
emitted once the request starts producing tokens).  Similarly,
prefix-cache hits (`num_cached_tokens`) are only known to the
OutputProcessor after prefill completes.  This overestimates the
real backlog, causing earlier rejection than strictly necessary
— the safe direction for QoS.  The impact is limited to long
prompts under chunked prefill; short prompts that prefill in a
single iteration are unaffected.

Parse human-readable integers like '1k', '2M', etc.
    Including decimal values with decimal multipliers.

```
Examples:
- '1k' -> 1,000
- '1K' -> 1,024
- '25.6k' -> 25,600
```

#### `--long-prefill-token-threshold`

For chunked prefill, a request is considered long if the prompt is
longer than this number of tokens. 0 disables the cap (default).

The cap is not applied when the request is the only one in the batch,
since there is no other request for it to starve.

**Default:** `0`

#### `--long-prefill-token-threshold-adaptive`, `--no-long-prefill-token-threshold-adaptive`

Floor the effective long prefill token threshold at a fair share of
the token budget: max_num_batched_tokens divided by the number of
queued and running requests. Only applies when
long_prefill_token_threshold is nonzero.
**Default:** `False`

#### `--scheduling-policy`

**Choices:** `fcfs`, `priority`

The scheduling policy to use:

- "fcfs" means first come first served, i.e. requests are handled in order
  of arrival.

- "priority" means requests are handled based on given priority (lower
  value means earlier handling) and time of arrival deciding any ties).

**Default:** `fcfs`

#### `--enable-chunked-prefill`, `--disable-chunked-prefill`

If True, prefill requests can be chunked based
on the remaining `max_num_batched_tokens`.

The default value here is mainly for convenience when testing.
In real usage, this should be set in `EngineArgs.create_engine_config`.

#### `--disable-chunked-mm-input`, `--enable-chunked-mm-input`

If set to true and chunked prefill is enabled, we do not want to
partially schedule a multimodal item. Only used in V1
This ensures that if a request has a mixed prompt
(like text tokens TTTT followed by image tokens IIIIIIIIII) where only
some image tokens can be scheduled (like TTTTIIIII, leaving IIIII),
it will be scheduled as TTTT in one step and IIIIIIIIII in the next.
**Default:** `False`

#### `--scheduler-cls`

The scheduler class to use. "vllm.v1.core.sched.scheduler.Scheduler" is
the default scheduler. Can be a class directly or the path to a class of
form "mod.custom_class".

#### `--scheduler-reserve-full-isl`, `--no-scheduler-reserve-full-isl`

If True, the scheduler checks whether the full input sequence length
fits in the KV cache before admitting a new request, rather than only
checking the first chunk. Prevents over-admission and KV cache thrashing
with chunked prefill.
**Default:** `True`

#### `--watermark`

Fraction of total KV cache blocks to keep free (the watermark) when
admitting waiting or preempted requests into the running queue. This headroom
helps avoid frequent KV cache eviction and the resulting repeated preemption
of requests when GPU memory is scarce. Must be in the range [0.0, 1.0); 0.0
(the default) disables the watermark.
**Default:** `0.0`

#### `--prefill-schedule-interval`

Only admit prefill once every N engine steps, leaving the steps in
between to decode alone. 1 (the default) admits prefill on every step.

A deferred step carries no prefill at all, including chunks of an
already-admitted prompt, so a long prompt can take up to N times as many
steps to finish prefilling.

**Default:** `1`

#### `--disable-hybrid-kv-cache-manager`, `--enable-hybrid-kv-cache-manager`

If set to True, KV cache manager will allocate the same size of KV cache
for all attention layers even if there are multiple type of attention layers
like full attention and sliding window attention.
If set to None, the default value will be determined based on the environment
and starting configuration.

#### `--async-scheduling`, `--no-async-scheduling`

If set to False, disable async scheduling. Async scheduling helps to
avoid gaps in GPU utilization, leading to better latency and throughput.

#### `--stream-interval`

The interval (or buffer size) for streaming in terms of token length.
A smaller value (1) makes streaming smoother by sending each token immediately,
while a larger value (e.g., 10) reduces host overhead and may increase throughput
by batching multiple tokens before sending.
**Default:** `1`

### CompilationConfig

Configuration for compilation.

You must pass CompilationConfig to VLLMConfig constructor.
VLLMConfig's post_init does further initialization. If used outside of the
VLLMConfig, some fields will be left in an improper state.

It contains PassConfig, which controls the custom fusion/transformation passes.
The rest has three parts:

- Top-level Compilation control:

- [`mode`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.mode)

- [`debug_dump_path`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.debug_dump_path)

- [`cache_dir`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.cache_dir)

- [`backend`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.backend)

- [`custom_ops`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.custom_ops)

- [`splitting_ops`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.splitting_ops)

- [`compile_mm_encoder`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.compile_mm_encoder)

- CudaGraph capture:

- [`cudagraph_mode`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.cudagraph_mode)

- [`cudagraph_capture_sizes`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.cudagraph_capture_sizes)

- [`max_cudagraph_capture_size`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.max_cudagraph_capture_size)

- [`cudagraph_num_of_warmups`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.cudagraph_num_of_warmups)

- [`cudagraph_copy_inputs`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.cudagraph_copy_inputs)

- Inductor compilation:

- [`compile_sizes`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.compile_sizes)

- [`compile_ranges_endpoints`]
    [vllm.config.CompilationConfig.compile_ranges_endpoints]

- [`inductor_compile_config`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.inductor_compile_config)

- [`inductor_passes`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig.inductor_passes)

- custom inductor passes

Why we have different sizes for cudagraph and inductor:
- cudagraph: a cudagraph captured for a specific size can only be used
    for the same size. We need to capture all the sizes we want to use.
- inductor: a graph compiled by inductor for a general shape can be used
    for different sizes. Inductor can also compile for specific sizes,
    where it can have more information to optimize the graph with fully
    static shapes. However, we find the general shape compilation is
    sufficient for most cases. It might be beneficial to compile for
    certain small batchsizes, where inductor is good at optimizing.

#### `--cudagraph-capture-sizes`

Sizes to capture cudagraph.
- None (default): capture sizes are inferred from vllm config.
- list[int]: capture sizes are specified as given.

#### `--max-cudagraph-capture-size`

The maximum cudagraph capture size.

If cudagraph_capture_sizes is specified, this will be set to the largest
size in that list (or checked for consistency if specified). If
cudagraph_capture_sizes is not specified, the list of sizes is generated
automatically following the pattern:

```
[1, 2, 4] + list(range(8, 256, 8)) + list(
range(256, max_cudagraph_capture_size + 1, 16))
```

If not specified, max_cudagraph_capture_size is capped at 512 by default,
or 1024 on data center Blackwell GPUs. This avoids OOM in tight memory
scenarios with small max_num_seqs, and limits capture of large graphs that
increase startup time and memory usage. Uniform decode sizes are appended
only within this default ceiling.

### KernelConfig

Configuration for kernel selection and warmup behavior.

#### `--ir-op-priority`

vLLM IR op priority for dispatching/lowering during the forward pass.
Platform defaults appended automatically during VllmConfig.post_init.

Deprecated: vLLM IR is being removed, and this option will be removed in
v0.34.0. Kernels will be selected by the platform, as for other custom ops.

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `IrOpPriorityConfig(rms_norm=[], fused_add_rms_norm=[], gelu_and_mul_sparse=[])`

#### `--enable-flashinfer-autotune`, `--disable-flashinfer-autotune`

Benchmark FlashInfer kernel implementations during warmup and use the
fastest. Enabled by default except at `-O0`; disable for faster startup.

#### `--monokernel`, `--no-monokernel`

If True, run the eligible layers of decode steps on the model's
MonoKernel: a persistent kernel that runs most or all of one decoder layer
in a single launch (DeepSeek-V4.1 on MI355X, DeepSeek-V4-Pro at TP8 on
MI355X). A deployment that cannot run it is refused at startup.
**Default:** `False`

#### `--moe-backend`

**Choices:** `aiter`, `aiter_mega_moe`, `aiter_triton_mxfp4_bf16`, `aiter_triton_mxfp4_mxfp4`, `auto`, `b12x`, `batched_triton`, `cutlass`, `deep_gemm`, `deep_gemm_mega_moe`, `emulation`, `flashinfer_b12x`, `flashinfer_cutedsl`, `flashinfer_cutlass`, `flashinfer_moe_ep_cutedsl`, `flashinfer_moe_ep_mega_deep_gemm`, `flashinfer_trtllm`, `flydsl`, `hpc`, `humming`, `marlin`, `rdna3`, `triton`, `triton_unfused`

Backend for MoE expert computation kernels. Available options:

- "auto": Automatically select the best backend based on model and hardware

- "triton": Use Triton-based fused MoE kernels

- "batched_triton": Use batched Triton experts (moe_mmk) on the batched
  activation format ([E_local, max_num_tokens, K])

- "deep_gemm": Use DeepGEMM kernels (FP8 block-quantized only)

- "deep_gemm_mega_moe": Use DeepGEMM mega MoE kernels

- "cutlass": Use vLLM CUTLASS kernels

- "flashinfer_trtllm": Use FlashInfer with TRTLLM-GEN kernels

- "flashinfer_cutlass": Use FlashInfer with CUTLASS kernels

- "flashinfer_cutedsl": Use FlashInfer with CuteDSL kernels (FP4 only)

- "flashinfer_moe_ep_cutedsl": Use FlashInfer's CuTeDSL MoE-EP
  mega-kernel with NVFP4 weights (MXFP4 checkpoints are requantized at
  load); requires Blackwell, expert parallelism, and NVSHMEM

- "flashinfer_b12x": Use FlashInfer CuteDSL fused MoE for SM12x
  (RTX Pro 6000 / DGX Spark)

- "b12x": Use b12x FP4 MoE kernels on SM12x

- "flashinfer_moe_ep_mega_deep_gemm": Use the FlashInfer moe_ep
  expert-parallel mega-MoE with the DeepGEMM megakernel, which consumes an
  MXFP4 checkpoint verbatim (Blackwell, requires expert parallel;
  DeepSeek-V4 only)

- "marlin": Use Marlin kernels (weight-only quantization)

- "humming": Use Humming Mixed Precision kernels

- "triton_unfused": Use Triton unfused MoE kernels

- "aiter": Use AMD AITer kernels (ROCm only)

- "aiter_mega_moe": Use the AITER MegaMoE fused dispatch/GEMM/combine
  kernel (ROCm gfx950, requires DP+EP with a MoRI all2all backend;
  DeepSeek-V4 only)

- "aiter_triton_mxfp4_bf16": Use the AITER Triton MXFP4 W4A16
  (moe_gemm_a16w4) MoE kernel (ROCm gfx942/gfx950/gfx1250)

- "aiter_triton_mxfp4_mxfp4": Use the AITER Triton/Gluon MXFP4 W4A4
  (moe_gemm_a4w4) MoE kernel (ROCm gfx1250)

- "flydsl": Use AMD FlyDSL kernels (ROCm only)

- "rdna3": Use the fused RDNA3 W4A16 HIP kernel (ROCm gfx1100 only)

- "hpc": Use HPC kernels (FP8 and Hopper only)

- "emulation": use BF16/FP16 GEMM, dequantizing weights and
               running QDQ on activations.

**Default:** `auto`

#### `--linear-backend`

**Choices:** `aiter`, `auto`, `b12x`, `conch`, `cutlass`, `deep_gemm`, `emulation`, `exllama`, `fbgemm`, `flashinfer_b12x`, `flashinfer_cudnn`, `flashinfer_cutedsl`, `flashinfer_cutlass`, `flashinfer_trtllm`, `humming`, `machete`, `marlin`, `torch`, `triton`, `xpu`, `xpu_woq`

Backend for linear layer GEMM kernels. Available options:

Layer types without an implementation from the requested backend use
automatic selection.

- "auto": Automatically select the best backend based on model and hardware

- "cutlass": Use CUTLASS-based kernels

- "flashinfer_cutlass": Use FlashInfer with CUTLASS kernels

- "flashinfer_cutedsl": Use FlashInfer with CuTe-DSL kernels
  (BF16, NVFP4, MXFP8, W4A16_NVFP4)

- "flashinfer_trtllm": Use FlashInfer with TensorRT-LLM kernels

- "flashinfer_cudnn": Use FlashInfer with cuDNN kernels

- "flashinfer_b12x": Use FlashInfer b12x CuteDSL NVFP4 GEMM (SM120+)

- "b12x": Use native B12X FP8 and FP4 linear kernels on SM12x

- "marlin": Use Marlin kernels

- "triton": Use Triton-based kernels

- "deep_gemm": Use DeepGEMM kernels

- "torch": Use PyTorch native scaled_mm kernels

- "aiter": Use AMD AITer kernels (ROCm only)

- "machete": Use Machete kernels (mixed-precision)

- "fbgemm": Use FBGEMM kernels

- "conch": Use Conch mixed-precision kernels

- "exllama": Use Exllama mixed-precision kernels

- "emulation": Use slow dequant-to-BF16 emulation (for testing only)

- "xpu": Use XPU kernels

- "xpu_woq": Use XPU kernels for weight-only quantization (e.g. W8A16)

**Default:** `auto`

#### `--sparse-indexer-topk-backend`

**Choices:** `aiter`, `auto`, `cooperative`, `deep_select`, `flashinfer`, `per_row`, `persistent`, `torch`

Backend for the DSA sparse indexer decode top-k kernel. Available options:

- "auto": The pre-existing chain (cooperative -> persistent -> per_row);
  the other backends are opt-in

- "deep_select": Use DeepSelect kernels (SM100a/SM103a only)

- "cooperative": Use vLLM's cooperative_topk kernel

- "persistent": Use vLLM's persistent_topk kernel

- "per_row": Use vLLM's top_k_per_row_decode kernel

- "flashinfer": Use FlashInfer's top_k_ragged_transform kernel

- "torch": Use a plain torch.topk implementation (debug reference)

- "aiter": Use AITER's top_k_per_row_decode kernel (ROCm gfx950 only,
  requires VLLM_ROCM_USE_AITER)

Explicit values raise RuntimeError when their constraints are not met.

**Default:** `auto`

### VllmConfig

Dataclass which contains all vllm-related configuration. This
simplifies passing around the distinct configurations in the codebase.

#### `--speculative-config`, `-sc`

Speculative decoding configuration.

API docs: [`vllm.config.SpeculativeConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.SpeculativeConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--spec-method`

**Choices:** `bailing_hybrid_mtp`, `bailing_hybrid_v3_mtp`, `custom_class`, `deepseek_mtp`, `dflash`, `dots3_note_mtp`, `draft_model`, `dspark`, `eagle`, `eagle3`, `ernie_mtp`, `exaone4_5_mtp`, `exaone_moe_mtp`, `extract_hidden_states`, `gemma4_mtp`, `glm4_moe_lite_mtp`, `glm4_moe_mtp`, `glm5_next_mtp`, `glm_ocr_mtp`, `hy_v3_mtp`, `hy_v4_mtp`, `inkling_mtp`, `kimi_k3_mtp`, `longcat_flash_mtp`, `mimo_mtp`, `mimo_v2_mtp`, `minimax_m3_mtp`, `mtp`, `nemotron_h_mtp`, `ngram`, `ngram_gpu`, `pangu_ultra_moe_mtp`, `qwen3_5_mtp`, `qwen3_next_mtp`, `qwen4_exp_mtp`, `step3p5_mtp`, `step5_mtp`, `suffix`, `None`

The name of the speculative method to use. If users provide and set the
`model` param, the speculative method type will be detected automatically
if possible, if `model` param is not provided, the method name must be
provided.

If using `ngram` method, the related configuration `prompt_lookup_max` and
`prompt_lookup_min` should be considered.

#### `--spec-model`

The name of the draft model, eagle head, or additional weights, if
provided.

#### `--spec-tokens`

The number of speculative tokens, if provided. It will default to the
number in the draft model config if present, otherwise, it is required.

#### `--watermark-config`

Text watermarking configuration.

API docs: [`vllm.config.WatermarkConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.WatermarkConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--diffusion-config`, `-dc`

Diffusion LLM (dLLM) configuration.

API docs: [`vllm.config.DiffusionConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.DiffusionConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--kv-transfer-config`

The configurations for distributed KV cache transfer.

API docs: [`vllm.config.KVTransferConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.KVTransferConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--kv-events-config`

The configurations for event publishing.

API docs: [`vllm.config.KVEventsConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.KVEventsConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--ec-transfer-config`

The configurations for distributed EC cache transfer.

API docs: [`vllm.config.ECTransferConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.ECTransferConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--ec-manager-config`

The configurations for custom encoder cache manager.

API docs: [`vllm.config.EncoderCacheManagerConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.EncoderCacheManagerConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `EncoderCacheManagerConfig(encoder_cache_manager_cls=None, manager_config={})`

#### `--compilation-config`, `-cc`

`torch.compile` and cudagraph capture configuration for the model.

As a shorthand, one can append compilation arguments via
-cc.parameter=argument such as `-cc.mode=3` (same as `-cc='{"mode":3}'`).

You can specify the full compilation config like so:
`{"mode": 3, "cudagraph_capture_sizes": [1, 2, 4, 8]}`

API docs: [`vllm.config.CompilationConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.CompilationConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `{'mode': None, 'debug_dump_path': None, 'cache_dir': '', 'compile_cache_save_format': 'binary', 'backend': 'inductor', 'custom_ops': [], 'ir_enable_torch_wrap': None, 'splitting_ops': None, 'compile_mm_encoder': False, 'cudagraph_mm_encoder': False, 'encoder_cudagraph_token_budgets': [], 'encoder_cudagraph_max_vision_items_per_batch': 0, 'encoder_cudagraph_max_frames_per_batch': None, 'cudagraph_decoder_replay': True, 'decoder_replay_cudagraph_capture_sizes': [], 'decoder_replay_trim_threshold': 768, 'compile_sizes': None, 'compile_ranges_endpoints': None, 'inductor_compile_config': {'enable_auto_functionalized_v2': False, 'combo_kernels': True, 'benchmark_combo_kernel': False}, 'inductor_passes': {}, 'cudagraph_mode': None, 'cudagraph_num_of_warmups': 0, 'cudagraph_capture_sizes': None, 'cudagraph_copy_inputs': False, 'cudagraph_specialize_lora': True, 'use_inductor_graph_partition': None, 'pass_config': {}, 'max_cudagraph_capture_size': None, 'dynamic_shapes_config': {'type': <DynamicShapesType.BACKED: 'backed'>, 'evaluate_guards': False, 'assume_32_bit_indexing': False}, 'local_cache_dir': None, 'fast_moe_cold_start': None, 'static_all_moe_layers': []}`

#### `--attention-config`, `-ac`

Attention configuration.

API docs: [`vllm.config.AttentionConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.AttentionConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `AttentionConfig(backend=None, minimax_m3_msa_decode_backend='triton', backend_per_kind={}, flash_attn_version=None, flash_attn_max_num_splits_for_cuda_graph=32, tokenspeed_mla_min_split_kv=1, tq_max_kv_splits_for_cuda_graph=32, use_trtllm_attention=None, disable_flashinfer_q_quantization=False, mla_prefill_backend=None, use_prefill_query_quantization=False, trtllm_ragged_backend='trtllm-gen', indexer_kv_dtype='auto', indexer_sparse_logits=False, indexer_tp_shard_min_rows=65536, minimax_m3_indexer_cp=False, hisparse_config=None, use_non_causal=False, sparse_mla_force_mqa=False, sparse_mla_prefill_workspace_factor=None, flex_attn_block_m=None, flex_attn_block_n=None, flex_attn_q_block_size=None, flex_attn_kv_block_size=None)`

#### `--engram-config`

N-gram embedding storage and sharding settings.

API docs: [`vllm.config.EngramConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.EngramConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--reasoning-config`

The configurations for reasoning model.

API docs: [`vllm.config.ReasoningConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.ReasoningConfig)

Should either be a valid JSON string or JSON keys passed individually.

#### `--kernel-config`

Kernel configuration.

API docs: [`vllm.config.KernelConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.KernelConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `KernelConfig(ir_op_priority=IrOpPriorityConfig(rms_norm=[], fused_add_rms_norm=[], gelu_and_mul_sparse=[]), enable_flashinfer_autotune=None, enable_rocm_segmented_attn_autotune=False, enable_cutedsl_warmup=True, enable_jit_warmup=True, monokernel=False, moe_backend='auto', sparse_indexer_topk_backend='auto', linear_backend='auto', linear_backend_per_quant=None)`

#### `--additional-config`

Additional config for specified platform. Different platforms may
support different configs. Make sure the configs are valid for the platform
you are using. Contents must be hashable.
**Default:** `{}`

#### `--structured-outputs-config`

Structured outputs configuration.

API docs: [`vllm.config.StructuredOutputsConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.StructuredOutputsConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `StructuredOutputsConfig(backend='auto', disable_any_whitespace=False, disable_additional_properties=False, reasoning_parser='', reasoning_parser_plugin='', enable_in_reasoning=False)`

#### `--aux-output-config`

Execution auxiliary output configuration.

API docs: [`vllm.config.AuxOutputConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.AuxOutputConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `AuxOutputConfig(enable_return_routed_experts=False, max_bytes=None)`

#### `--profiler-config`

Profiling configuration.

API docs: [`vllm.config.ProfilerConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.ProfilerConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `ProfilerConfig(profiler=None, torch_profiler_dir='', torch_profiler_activities=None, proton_profiler_dir='', proton_context='shadow', proton_data='tree', proton_backend=None, proton_mode=None, proton_hook=None, proton_output_format=None, proton_graph_attribution=False, torch_profiler_with_stack=True, torch_profiler_with_flops=False, torch_profiler_use_gzip=True, torch_profiler_dump_cuda_time_total=True, torch_profiler_record_shapes=False, torch_profiler_with_memory=False, capture_torch_profiler=False, detailed_trace_annotation=False, ignore_frontend=False, delay_iterations=0, max_iterations=0, warmup_iterations=0, active_iterations=5, wait_iterations=0)`

#### `--watchdog-config`

Configuration for the stack-dump watchdog.

API docs: [`vllm.config.WatchdogConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.WatchdogConfig)

Should either be a valid JSON string or JSON keys passed individually.

**Default:** `WatchdogConfig(timeout=300, check_interval=10, dump_dir='')`

#### `--optimization-level`

The optimization level. These levels trade startup time cost for
performance, with -O0 having the best startup time and -O3 having the best
performance. -O2 is used by default. See OptimizationLevel for full
description.
**Default:** `2`

#### `--performance-mode`

**Choices:** `balanced`, `interactivity`, `throughput`
Performance mode for runtime behavior, 'balanced' is the default.
'interactivity' favors low end-to-end per-request latency at small batch
sizes (fine-grained CUDA graphs, latency-oriented kernels).
'throughput' favors aggregate tokens/sec at high concurrency (larger CUDA
graphs, more aggressive batching, throughput-oriented kernels).
**Default:** `balanced`

#### `--weight-transfer-config`

The configurations for weight transfer during RL training.

API docs: [`vllm.config.WeightTransferConfig`](https://docs.vllm.ai/en/api/vllm/config/#vllm.config.WeightTransferConfig)

Should either be a valid JSON string or JSON keys passed individually.

    November 1, 2026
