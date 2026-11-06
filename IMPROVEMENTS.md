# ECR engine images and S3 model releases

The engine and weights have independent releases. See [ecr/README.md](ecr/README.md)
and [models/README.md](models/README.md) for publishing and deployment.

| What changed | Change code | Purpose | What could be next |
| --- | --- | --- | --- |
| Separate artifact ownership | [llm-artifact-infra](https://github.com/wlodarczyk-devops/llm-artifact-infra) | Retain S3/ECR independently of the cluster with separate remote state and publisher identities | Provision remote state and migrate existing states before applying |
| Manual model publishing | [publish-model.yml](.github/workflows/publish-model.yml), [open_release_pr.py](models/open_release_pr.py) | Upload via OIDC, then open a release PR in a separate job without AWS credentials | Provision role/bucket, configure Actions variables, merge and verify a real run |
| Separate engine/downloader images | [`ecr/image`](ecr/image), digest lookups in [`vllm/image.tf`](vllm/image.tf) | Mirror the official vLLM image without an engine build; build only the downloader; both images pull privately | Scan acceptance and image signing in publishing CI |
| Private versioned model bucket | [`llm-artifact-infra/models`](https://github.com/wlodarczyk-devops/llm-artifact-infra/tree/main/models) | Encrypt weights, block public access, retain versions and require TLS | Object data-event audit logging, optional SSE-KMS |
| One model publisher | [`models/publish.py`](models/publish.py), [`models/release.json`](models/release.json) | Upload one archive and pin its exact S3 version/checksum without per-file Terraform resources | Signed provenance and promotion policy |
| Private image, model and identity paths | ECR/S3 endpoints plus STS in [`vpc/ecr-endpoints.tf`](vpc/ecr-endpoints.tf) | Keep ECR pulls, S3 downloads and regional IRSA credential exchange on AWS private paths | Endpoint cost review; scoped shared endpoint policies |
| Exact-version, endpoint-scoped IRSA | [`vllm/model-storage.tf`](vllm/model-storage.tf) | Grant only GetObjectVersion on the selected archive/version via the S3 endpoint | Negative-access verification and bounded old/new-version overlap for upgrades |
| One init container | [`vllm/main.tf`](vllm/main.tf) | Download, verify SHA-256 and extract before serving; mount identity only in the downloader | Measured startup budgets and persistent caching if needed |
| Offline serving with read-only local weights | Model volume and offline settings in the deployment | Preserve the API model name and keep AWS tokens out of the serving container | Workload network isolation and GPU/capacity validation |
| Repository cleanup | [README inventory](README.md#what-is-still-needed), vLLM configuration/docs | Use one model identity source, replace the copied CLI dump with an upstream link, and explain the retained downloader/build files | Revisit optional developer tooling only if its workflow is no longer used |

No tests directory is included. Static parsing/format checks passed; deployment,
image publishing and model uploading remain pending. No Terraform commands or
AWS/Kubernetes mutations were run by the agent.
