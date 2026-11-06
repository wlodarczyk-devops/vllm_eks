# vllm_eks

Terraform for serving an open-weight LLM with [vLLM](https://docs.vllm.ai) on a GPU node of an Amazon EKS cluster in `eu-central-1`.

The model, `Qwen/Qwen3-4B-Instruct-2507`, is served through vLLM's OpenAI-compatible API.
Engine/downloader images are stored in private ECR; model weights are a versioned
S3 archive. One init container downloads and verifies the selected model before
vLLM serves local files offline. See [ecr/README.md](ecr/README.md) and
[models/README.md](models/README.md) for publishing and deployment.

## Architecture

```text
AWS eu-central-1
├── ECR vllm-eks-vllm  engine/downloader images               (ecr/)
├── S3 vllm-eks-models-<account>-eu-central-1  versioned weights  (models/)
└── VPC vllm-eks  10.0.0.0/16                                   (vpc/)
    ├── public subnets  ×3 AZ  10.0.48.0/24, 10.0.49.0/24, 10.0.50.0/24   ← single NAT gateway
    └── private subnets ×3 AZ  10.0.0.0/20,  10.0.16.0/20, 10.0.32.0/20
        └── EKS cluster vllm-eks, Kubernetes 1.37               (eks/)
            ├── node group "system"  t3.medium × 1 (1–2)       ← CoreDNS, add-ons, llm-d Router
            ├── node group "gpu"     g4dn / g5 / g6 .xlarge × 2 (0–2)
            │     taint nvidia.com/gpu=true:NoSchedule
            │     └── nvidia-device-plugin (kube-system)
            ├── namespace vllm                                  (vllm/)
            │     ├── Deployment vllm  2 × Qwen3-4B-Instruct-2507 (1 per GPU node), fp16, 16k context
            │     └── Service vllm     ClusterIP :8000           ← connection balancing
            ├── namespace vllm: llm-d Router (PoC)               (llm-d/)
            │     ├── Deployment llm-d-epp  EPP + Envoy sidecar  (system node)
            │     ├── Service llm-d-epp     ClusterIP :80        ← prefix-cache/load-aware
            │     └── InferencePool llm-d   selects app=vllm pods
            ├── add-ons: vpc-cni, coredns, kube-proxy; IRSA enabled
            └── cluster-autoscaler (kube-system, system node)   ← scales both node groups within min/max
```

## Repository layout

```text
.
├── vpc/                 # Terraform: VPC, subnets, NAT gateway, EKS subnet tags
├── ecr/                 # Terraform: private engine/downloader image repository
├── models/              # Terraform: private model bucket; one model publishing script
├── eks/                 # Terraform: EKS cluster, node groups, NVIDIA device plugin
├── vllm/                # Terraform: vLLM namespace, Deployment, Service
│   └── README.md        # deployment settings and selected tuning options
├── llm-d/               # Terraform: llm-d Router PoC (InferencePool CRD, router Helm chart)
│   └── README.md        # how llm-d works and how to test it
├── .github/workflows/
│   └── claude-review.yml  # Claude PR review on "@claude" comments
├── CLAUDE.md            # guidelines for Claude Code in this repo
└── README.md
```

## What is still needed

| Component | Decision | Reason |
| --- | --- | --- |
| `vpc/` | Keep | Networking, NAT for remaining external dependencies, and private ECR/S3/STS access |
| `eks/` | Keep | Cluster, CPU/GPU nodes, NVIDIA plugin, CNI identity and autoscaling |
| `ecr/` | Keep | Engine/downloader repository and image publishing |
| `models/` | Keep | S3 bucket infrastructure, model publishing, and the selected artifact's version/checksum |
| `vllm/` | Keep | Model-reader IRSA, init download, GPU serving and Service |
| `llm-d/` and its values files | Keep for the selected routing design | Cache/load-aware routing; the plain vLLM Service can serve without this optional router |
| `versions.tf`, variables, tfvars, outputs and lockfiles | Keep in each stack | Separate state roots have their own provider/configuration contracts; repeated filenames are intentional |
| Publishing scripts and release JSON files | Keep | Terraform creates infrastructure; these publish and select the actual images/model |
| `Dockerfile.downloader` and `.dockerignore` | Keep | Build only the archive-download tool image; see [why it exists](ecr/README.md#why-dockerfiledownloader-remains) |
| `CLAUDE.md` and the Claude review workflow | Optional developer tooling, kept | Used for the repository's existing authoring/review workflow; not a serving dependency |

The source folder `models/` contains code/configuration, not weights. The S3 archive
holds the durable weights; `/models/model` inside a pod is the temporary extracted
copy. These are three different locations.

The engine Dockerfile and test directory have already been removed. The copied
upstream CLI dump and duplicate deployment model-name setting are also removed;
`models/release.json` is the source of the served model name. Keep Terraform state
files for existing resources. Ignored `.terraform/` directories are downloaded
caches, not obsolete application code or a substitute for state.

Each Terraform folder is a separate stack with the same files:

| File | Content |
|---|---|
| `versions.tf` | Terraform and provider versions, provider configuration |
| `main.tf` | Resources and modules |
| `variables.tf` | All settings, with types and descriptions and no defaults |
| `terraform.tfvars` | The values of those settings (plain values, never secrets) |
| `outputs.tf` | Values other stacks or you need |
| `.terraform.lock.hcl` | Locked provider versions (committed) |

State is stored locally in each folder (`terraform.tfstate`, ignored by git).

## Prerequisites

- Terraform `>= 1.13`
- AWS CLI v2 with credentials for the target account (`aws sts get-caller-identity` works)
- `kubectl`
- `helm` (only for `helm show`/`template` when exploring the llm-d chart; Terraform installs it)
- EC2 quota **Running On-Demand G and VT instances** of at least 8 vCPUs in `eu-central-1` (two `*.xlarge` GPU nodes, 4 vCPUs each). Check it with:
  ```bash
  aws service-quotas get-service-quota --region eu-central-1 --service-code ec2 --quota-code L-DB2E81BA
  ```

## Deploy

The stacks depend on each other and must be applied in this order.

### 1. VPC

```bash
cd vpc
terraform init
terraform apply
```

Creates the VPC across 3 AZs (`eu-central-1a/b/c`) with:

- **Private subnets** (`/20`, 4,096 addresses each) for nodes and pods. The VPC CNI gives every pod a VPC IP, so they're large.
- **Public subnets** (`/24`) for load balancers and the NAT gateway.
- **One NAT gateway** for outbound traffic from the private subnets. It's cheaper than one per AZ, but if its AZ fails, private subnets lose internet access.
- **EKS tags** so AWS can place load balancers: `kubernetes.io/role/elb=1` (public), `kubernetes.io/role/internal-elb=1` (private), and `kubernetes.io/cluster/vllm-eks=shared` (both).

Module: [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws) `6.7.3`.

### 2. EKS

The EKS stack reads the VPC ID and subnets from `../vpc/terraform.tfstate`, so apply the VPC first.

The public API endpoint only accepts the CIDRs in `endpoint_public_access_cidrs`. Your IP isn't committed; pass it at runtime:

```bash
cd eks
export TF_VAR_endpoint_public_access_cidrs="[\"$(curl -s ifconfig.me)/32\"]"
terraform init
terraform apply
$(terraform output -raw configure_kubectl)   # adds the cluster to ~/.kube/config
```

If your IP changes, re-run the `export` and `terraform apply`, or `kubectl` is locked out. Nodes use the private endpoint and aren't affected.

What it creates:

| Component | Details |
|---|---|
| Cluster | `vllm-eks`, Kubernetes `1.37`, in the private subnets. IRSA (OIDC provider) enabled. The identity that runs `apply` gets cluster-admin. |
| Add-ons | `vpc-cni` (installed before nodes, dedicated IRSA role for `kube-system:aws-node`), `coredns`, `kube-proxy` |
| Node group `system` | `t3.medium`, 1 node (scales 1–2), `AL2023_x86_64_STANDARD` AMI. Runs CoreDNS and other add-ons. |
| Node group `gpu` | Up to 2 nodes (scales 0–2), one per vLLM replica; Cluster Autoscaler adds a node for each `Pending` replica. `AL2023_x86_64_NVIDIA` AMI (NVIDIA driver preinstalled), 100 GiB gp3 disk for the vLLM image and model. Labels `nvidia.com/gpu.present=true` and `k8s.amazonaws.com/accelerator=nvidia` (Cluster Autoscaler's GPU label), taint `nvidia.com/gpu=true:NoSchedule` so only GPU workloads run there. DaemonSets like `kube-proxy` and `vpc-cni` tolerate all taints and run on every node. |
| NVIDIA device plugin | Helm chart `0.20.1` in `kube-system`. Makes `nvidia.com/gpu` a resource pods can request. |
| Cluster Autoscaler | `v1.37.0` (Helm chart `9.60.0`) in `kube-system` on the system node. Adds nodes when pods are `Pending` for lack of resources (e.g. a vLLM replica needing a GPU) and removes nodes that have been unneeded for 10 min, always within each node group's `min_size`/`max_size`. Finds the node groups by the tags EKS sets on their Auto Scaling groups. AWS access via IRSA (role `vllm-eks-cluster-autoscaler`, may only resize this cluster's groups). Never removes a node running pods with `emptyDir` (vLLM) or `kube-system` pods. |

GPU instance types are tried in order, in every AZ, until one has capacity:

| Instance | GPU | GPU memory | vCPU / RAM |
|---|---|---|---|
| `g4dn.xlarge` | NVIDIA T4 | 16 GiB | 4 / 16 GiB |
| `g5.xlarge` | NVIDIA A10G | 24 GiB | 4 / 16 GiB |
| `g6.xlarge` | NVIDIA L4 | 24 GiB | 4 / 16 GiB |

GPU capacity in `eu-central-1` is often short. If node creation fails with `InsufficientInstanceCapacity`, retry later or add more types to `gpu_instance_types`.

Module: [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws) `21.29.0`.

#### VPC CNI IAM identity: first migration step

[`eks/vpc-cni-irsa.tf`](eks/vpc-cni-irsa.tf) creates a dedicated role with
the IAM module's IPv4 VPC CNI policy. Its trust policy permits only this cluster's
`kube-system:aws-node` service account, with the STS audience. The managed VPC CNI
add-on receives this role through `service_account_role_arn`; no separate service
account resource is needed. The IAM module version matches the existing
Cluster Autoscaler integration.

Node-role CNI permissions remain attached during this step. After deployment,
verify the `aws-node` service account annotation, the role's trust/policy attachment,
and that every running `aws-node` pod has `AWS_ROLE_ARN` and
`AWS_WEB_IDENTITY_TOKEN_FILE` configured. Existing pods may need a controlled
restart to receive the IRSA settings. Confirm successful web-identity role
assumption in CloudTrail and test pod IP allocation, including on a new node.
Working networking alone is insufficient evidence while node-role permissions
remain available as a fallback.

Removing CNI permissions from node roles is a separate follow-up after those
checks pass. The add-on also sets `enableNetworkPolicy = "true"` to enable
NetworkPolicy enforcement. Traffic restrictions require separate Kubernetes
`NetworkPolicy` resources; enabling the feature alone does not isolate pods.
See [AWS's VPC CNI IRSA guidance](https://docs.aws.amazon.com/eks/latest/userguide/cni-iam-role.html).

Check the result:

```bash
kubectl get nodes -L nvidia.com/gpu.present
kubectl -n kube-system get pods -o wide        # CoreDNS on system nodes, device plugin on the GPU node
kubectl describe node -l nvidia.com/gpu.present=true | grep nvidia.com/gpu   # nvidia.com/gpu: 1
```

### Publish images and model weights (before vLLM)

Create/publish the engine and downloader images following
[`ecr/README.md`](ecr/README.md), then create the model bucket and publish the
pinned snapshot following [`models/README.md`](models/README.md). Image releases
are in `ecr/image/release.json`; the model version/checksum is in
`models/release.json`. The VPC provides ECR API/registry and STS interface endpoints
plus one shared S3 gateway endpoint. Publish both images and the model before
planning vLLM. No per-file model objects or cross-stack local state are needed.

### 3. vLLM

```bash
cd vllm
terraform init
terraform apply
```

The stack finds the cluster by name (`cluster_name`) through the AWS API, so it doesn't read the EKS state. New nodes pull the engine/downloader images from ECR. An init container downloads the pinned S3 model version and verifies it before vLLM loads local weights offline. Image pulls, model preparation and warm-up can take several minutes. `apply` waits for the pod to become ready, up to `rollout_timeout` (60 min). The startup probe separately gives vLLM `startup_timeout_seconds` (20 min) after the container starts before restarting it.

| Setting | Value |
|---|---|
| Image | Separate engine/downloader images in private ECR, resolved from immutable release tags to digests |
| Configuration | Values set as `SERVE_*` container environment variables, referenced in `args` as `$(SERVE_...)` (see [`vllm/README.md`](vllm/README.md#how-options-are-set-in-this-repository)) |
| API server | `--host 0.0.0.0 --port 8000`. `port` also sets the container port, Service and probes. Service env injection is disabled (`enable_service_links = false`) so the Service named `vllm` can't set `VLLM_PORT`. |
| Model | `Qwen/Qwen3-4B-Instruct-2507`: Apache 2.0, not gated (no Hugging Face token), 4.0B parameters |
| Precision | `--dtype half` (fp16). The T4 has no bf16 support, so fp16 is used on every node type. |
| Context | `--max-model-len 16384` |
| GPU memory | `--gpu-memory-utilization 0.90` |
| Placement | Node selector `nvidia.com/gpu.present=true`, toleration for the GPU taint, 1 × `nvidia.com/gpu` |
| Resources | CPU request 2, memory request 8Gi / limit 12Gi, `/dev/shm` 2Gi |
| Model storage | Weights are extracted from the versioned S3 archive into `/models/model` and mounted read-only by vLLM. `/home/vllm` (`home_size` 30Gi) holds writable runtime caches; `/tmp` is a separate `emptyDir` (`tmp_size` 5Gi). |
| Security | Namespace enforces the `restricted` [Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/). The pod runs as the image's non-root `vllm` user (UID 2000, GID 0) with a read-only root filesystem, no privilege escalation, all capabilities dropped, the `RuntimeDefault` seccomp profile and no automatically mounted Kubernetes API token. Only the downloader mounts an STS-audience token. Writable paths: `/home/vllm`, `/tmp`, `/dev/shm`. |
| Replicas | 2 (`replicas`), one per GPU node |
| Probes | Startup probe on `/health` (20 min budget), liveness on `/health`, readiness on `/v1/models` (llm-d recommendation) |
| Updates | Rolling update with `maxSurge 0` / `maxUnavailable 1`: one pod is replaced at a time, because there's no spare GPU for an extra pod |
| Graceful shutdown | llm-d's pattern: `preStop` sleep 15 s (the pod leaves the Service/InferencePool), then `--shutdown-timeout 45` lets in-flight requests finish; grace period 75 s. Access logs skip `/health`, `/metrics`, `/v1/models`. |
| Service | `ClusterIP` on `port` (8000, not exposed outside the cluster) |

Why this model fits: on the smallest GPU (T4, 16 GiB), the fp16 weights take ~7.5 GiB. Each token in the KV cache takes ~144 KiB. With 90% of GPU memory in use, ~4.6 GiB (~33k tokens) is left for the KV cache, so 2 full 16k-token requests fit at once. On A10G/L4 there's ~11.5 GiB (~84k tokens).

To change the model or tune vLLM, see [`vllm/README.md`](vllm/README.md). It explains deployment settings and links to the full upstream CLI reference.

### 4. llm-d Router (PoC)

```bash
cd llm-d
terraform init
terraform apply
```

Proof of concept ([#12](https://github.com/wlodarczyk-devops/vllm_eks/issues/12)): the [llm-d](https://llm-d.ai) Router in Standalone Mode in front of the 2 vLLM pods, with llm-d's **Optimized Baseline** routing (prefix-cache and load aware). It runs on the CPU system node and under the `restricted` Pod Security Standard. See [`llm-d/README.md`](llm-d/README.md) for how it works and how to test it.

## Use the API

```bash
cd vllm
$(terraform output -raw port_forward)          # keep running: forwards localhost:8000 to the Service
```

In another terminal:

```bash
curl -s localhost:8000/v1/models

curl -s localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-4B-Instruct-2507", "messages": [{"role": "user", "content": "Hello!"}]}'
```

Any OpenAI-compatible client works with `base_url=http://localhost:8000/v1`. Prometheus metrics are at `localhost:8000/metrics`.

Troubleshooting:

```bash
kubectl -n vllm get pods -o wide
kubectl -n vllm logs deploy/vllm -c download-model  # S3 download/checksum/extraction
kubectl -n vllm logs deploy/vllm -c vllm -f         # engine load, KV cache, request stats
kubectl -n vllm describe pod -l app=vllm      # scheduling problems, e.g. no GPU node
```

## Cost and teardown

GPU nodes, NAT, EKS and interface endpoints incur recurring charges. Tear down compute/network resources in reverse order when finished; ECR and S3 releases are retained separately for rollback:

```bash
cd llm-d && terraform destroy
cd ../vllm && terraform destroy
cd ../eks && terraform destroy     # needs TF_VAR_endpoint_public_access_cidrs set
cd ../vpc && terraform destroy
```

To pause only the GPU nodes, scale vLLM to 0 instead of the node group. Cluster Autoscaler would add a node back for any `Pending` vLLM pod, and the EKS module ignores later changes to `gpu_desired_size` anyway.

1. Set `replicas = 0` in `vllm/terraform.tfvars` and run `terraform apply` in `vllm/`.
2. Cluster Autoscaler removes the now empty GPU nodes after 10 min (`cluster_autoscaler_scale_down_unneeded_time`), down to `gpu_min_size` (0).
3. To start again, set `replicas` back and apply. The pending pods make Cluster Autoscaler add GPU nodes (up to `gpu_max_size`). Each new node pulls the image and the pod downloads the model again.

Check what Cluster Autoscaler is doing:

```bash
kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler -f   # the chart names it <release>-aws-cluster-autoscaler
kubectl -n kube-system get configmap cluster-autoscaler-status -o yaml   # per node group: health, scale-up/down state
```

## Configuration

Infrastructure and deployment settings are stack variables in `terraform.tfvars`.
Image selection lives in `ecr/image/release.json`; model identity/version/checksum
live in `models/release.json`. Settings that must match across stacks:

| Setting | Must be the same in |
|---|---|
| Cluster name `vllm-eks` | `vpc/` `cluster_name` (subnet tags), `eks/`, `ecr/`, `models/`, `vllm/`, `llm-d/` `cluster_name` |
| Region `eu-central-1` | `region` in all stacks, and `azs` in `vpc/` |
| GPU taint and label | `eks/main.tf` node group and `vllm/main.tf` toleration and node selector; `llm-d/main.tf` avoids nodes with the label |
| vLLM namespace, labels, port | `vllm/` (`namespace`, `app=vllm`, `port`) and `llm-d/` (`namespace`, `model_server_labels`, `model_server_port`) |
| GPU nodes vs vLLM replicas | `eks/` `gpu_max_size` ≥ `vllm/` `replicas` (one GPU per pod) |

The ECR repository and model bucket retain releases and have destruction guards; review their lifecycles separately from routine cluster teardown.

Secrets never go into `terraform.tfvars`. Pass them as environment variables (`TF_VAR_<name>`), like the public IP above.

## GitHub workflow

- **Issues** track the work; each is implemented on its own branch and merged with a pull request that closes it.
- **Claude review**: comment `@claude` on a pull request (comment, inline review comment or review) to get a review from Claude via [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action). Opening a PR doesn't trigger it. The workflow uses the `CLAUDE_CODE_OAUTH_TOKEN` repository secret (created with `claude setup-token`).
