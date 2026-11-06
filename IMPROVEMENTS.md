# Combined vLLM/model image

The S3 model-artifact proposal is replaced by one image containing vLLM and the
pinned model weights. See [ecr/README.md](ecr/README.md) for the operating steps.

| What changed | Change code | Purpose | What could be next |
| --- | --- | --- | --- |
| Private ECR repository | [`ecr/main.tf`](ecr/main.tf): immutable tags, encryption, push scanning and untagged-image cleanup | Store the engine and weights as one versioned release | Enforce scan acceptance in trusted publishing CI |
| Combined engine/model image | [`ecr/image/Dockerfile`](ecr/image/Dockerfile), [`release.json`](ecr/image/release.json) | Include the exact model commit in a digest-pinned vLLM base; serve offline | Image signing/provenance and measured build/pull times |
| Explicit publishing | [`ecr/image/publish.py`](ecr/image/publish.py) | Build for the x86_64 GPU fleet and push a new immutable tag without Terraform provisioners | CI with a short-lived publisher identity |
| Private image pulls | [`vpc/ecr-endpoints.tf`](vpc/ecr-endpoints.tf), [`vpc/s3-endpoint.tf`](vpc/s3-endpoint.tf) | Provide ECR API/registry endpoints and the required S3 gateway route for layers | Endpoint-cost review and tighter policies if the shared VPC needs them |
| Digest-pinned deployment | [`vllm/image.tf`](vllm/image.tf), [`vllm/main.tf`](vllm/main.tf) | Resolve the published release to a digest and serve local weights with the existing API name | GPU smoke checks and rollout/cold-start measurements |
| Unprivileged application identity | Dedicated vLLM ServiceAccount with no AWS role or mounted API token | Kubelet uses node permissions to pull the complete image; serving needs no AWS API access | Review node-role permissions and add workload network isolation separately |

No Terraform commands, image builds/pushes, or deployments were executed by the
agent. No tests directory is included. Existing S3 artifacts/state, if you created
them separately, require a deliberate migration; see the operating guide.
