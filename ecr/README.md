# One vLLM + model image in ECR

This replaces the separate S3 model bucket, upload stack, downloader/verifier init
containers and model-reader IRSA role. The image contains both vLLM and the pinned
Qwen model at `/opt/model`. Serving needs no Hugging Face or S3 API calls.

```text
Pinned vLLM base + pinned Hugging Face commit
  → Docker Buildx → private ECR repository
  → ECR API + registry endpoints + S3 gateway endpoint
  → EKS kubelet pulls image by digest
  → non-root vLLM serves /opt/model offline
```

## Files

| File | Purpose |
| --- | --- |
| `main.tf` | Private ECR repository, immutable tags, encryption, scanning on push and cleanup of untagged images |
| `image/release.json` | Single release definition: base digest, model commit, API model name and image tag |
| `image/Dockerfile` | Downloads model files in a build stage and copies only those files into the final image |
| `image/publish.py` | Explicit AWS login, x86_64 image build and push; refuses an existing release tag |
| `../vpc/ecr-endpoints.tf` | ECR API/registry endpoints with private DNS and HTTPS access from private subnet CIDRs |
| `../vpc/s3-endpoint.tf` | Gateway endpoint for the S3-backed ECR image layers; no application model bucket |
| `../vllm/image.tf` | Resolves the published release to an image digest and creates an unprivileged ServiceAccount |

## Deploy

Terraform owns infrastructure; Docker owns image construction. No build or upload
runs inside Terraform, and the vLLM stack does not depend on another stack's local
state. This change has not been applied or built by the agent.

1. Create the repository:

   ```bash
   cd ecr
   terraform init
   terraform apply
   cd ..
   ```

2. Review `ecr/image/release.json`, then build/push with a working Docker Buildx
   builder, Python 3 and AWS CLI credentials for the publishing role:

   ```bash
   python3 ecr/image/publish.py --region eu-central-1 --repository vllm-eks-vllm
   ```

   The build downloads approximately 8 GB of model weights and includes the large
   vLLM base image. Allow ample builder disk space (at least 50 GB as a starting
   point), network time and ECR storage. On Apple Silicon, use a builder capable
   of `linux/amd64`; emulation can be slower. The image targets the current x86_64
   GPU fleet. The script logs Docker into ECR using the normal credential store.

3. Review the ECR vulnerability scan. Scanning on push is enabled, but publishing
   does not itself enforce a vulnerability acceptance policy. Account-level ECR
   scanning configuration may control the scan behavior.

4. Apply `vpc/` to create the endpoints. Create/retain the EKS cluster as usual.
   ECR interface endpoints are billed per AZ and for data processed. With the
   configured three AZs, the two endpoints create six endpoint network interfaces.

5. Apply `vllm/`. The selected image must already exist or planning fails with an
   ECR image lookup error. The deployment resolves the release tag and uses
   `repository@sha256:...`, keeps the API model name, and loads `/opt/model` offline.
   Deploy/use llm-d as before.

The publishing machine needs internet access to Docker Hub and Hugging Face.
The GPU nodes pull this image privately from ECR, but other cluster components
may still need NAT/internet for their own registries. Do not remove NAT solely
because ECR endpoints exist.

## Permissions

- **Publisher:** `ecr:GetAuthorizationToken` on `*`, plus
  `ecr:DescribeRepositories`, `ecr:DescribeImages`, `ecr:BatchCheckLayerAvailability`,
  `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`,
  `ecr:PutImage`, and `ecr:BatchGetImage` scoped to this repository. Buildx features
  may need additional read operations; add only those actually used.
- **EKS node role:** image pull permissions. The pinned EKS module already attaches
  `AmazonEC2ContainerRegistryReadOnly` to managed node roles. The kubelet handles
  pulls before starting the application; no `imagePullSecret` is required here.
- **vLLM ServiceAccount:** no AWS role, no Kubernetes RoleBindings, and automatic
  API token mounting disabled. llm-d needs no AWS permission for this image.
- **Terraform deployer:** ECR infrastructure permissions for `ecr/`, and
  `ecr:DescribeRepositories`/`ecr:DescribeImages` for the image lookup in `vllm/`,
  alongside existing Kubernetes deployment permissions.

Both ECR interface endpoints use private DNS. Their security group accepts only
TCP 443 from the configured private subnet CIDRs. The S3 gateway endpoint is
associated with all private route tables. Default endpoint policies preserve
other authorized registry/S3 traffic; they do not grant IAM access on their own.
Application NetworkPolicies do not control kubelet image pulls.

## Updates and rollback

Update the model commit/base digest and choose a NEW `image_tag` in
`image/release.json`. Publish first, review the scan, then apply vLLM. Immutable
tags prevent overwriting an existing release. The final image digest identifies
both engine and weights; there is no runtime model download to drift separately.

For rollback, restore a previous release definition and apply vLLM. Tagged images
are retained; only untagged images older than 14 days are selected for cleanup.
Do not manually delete tags/images referenced by active or rollback deployments.
The repository has `force_delete=false` and `prevent_destroy` to guard ordinary
teardown while its declaration remains in configuration.

The existing rollout replaces one GPU pod at a time with no surge. The remaining
replica must handle traffic during the pull/warm-up. Large images still take time
to pull on new nodes; there is no promise of faster cold starts. Check actual
compressed/unpacked image size, the existing 100 GiB GPU disk and runtime cache
usage. Writable cache volumes remain; no model volume or copying init container
is needed, and the root filesystem remains read-only.

## Replacing an already applied S3 proposal

If the earlier S3 code was never applied, use this version directly. If you applied
it yourself, inspect the plan and retire/migrate the model-store resources and
reader role deliberately. Removing their declarations can schedule deletion even
if they previously had lifecycle guards. Keep stored model releases/backups until
the new image is deployed successfully. No existing bucket, state file or local
model download has been deleted by this change.

## Verification status

HCL parsing, Python syntax checks and whitespace validation can run without
Terraform, AWS mutations or a model download. No automated test directory is
included, as requested. The full image build, ECR push/scan, provider validation,
private pull and GPU serving must be verified in the deployment environment.

References:

- [ECR VPC endpoints and S3 layer routing](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)
- [ECR image tag immutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html)
- [ECR pull permissions on EKS](https://docs.aws.amazon.com/AmazonECR/latest/userguide/ECR_on_EKS.html)
