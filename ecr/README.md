# Private engine and downloader images

ECR stores two independent images in the same private repository:

- The vLLM engine, with no model weights included.
- An AWS CLI downloader with `tar`, `gzip` and `sha256sum` available.

Both bases are pinned by digest in `image/release.json`. Tags are immutable, push
scanning is enabled, and only untagged images older than 14 days are cleaned up.
Tagged releases remain available for rollback.

## Why Dockerfile.downloader remains

This file creates a startup tool image, separate from the vLLM engine. The init
container runs these operations before serving starts:

1. `aws s3api get-object` fetches the exact archive version using IRSA.
2. `sha256sum` checks its expected bytes.
3. `tar`/`gzip` extract the model into the shared volume.

The Dockerfile installs the extraction/checksum tools at build time and sets a
non-root default user. Pods then need no package installation or public package
repository access. The official AWS CLI image guarantees the AWS CLI interface,
not arbitrary bundled utilities; our derived image explicitly supplies its tools.
See [AWS's supported image interface](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-docker.html).

This image contains no model weights, GPU driver or serving engine. It exits when
the model is ready. `publish.py` builds it once per release, and the deployment
pulls its ECR digest. Removing this Dockerfile requires supplying an equivalent
prebuilt image or changing the archive-download design. The engine Dockerfile is
unnecessary because the official engine is mirrored and Kubernetes sets its
runtime options.

## Create and publish

In a deployment session, create the repository:

```bash
cd ecr
terraform init
terraform apply
cd ..
```

With Docker Engine API 1.46+ (for platform-specific pushes), Docker Buildx,
Python 3 and an AWS publishing identity:

```bash
python3 ecr/image/publish.py --region eu-central-1 --repository vllm-eks-vllm
```

The script mirrors the digest-pinned official vLLM image for `linux/amd64` using
pull/tag/push. There is no engine Dockerfile or engine build. The Kubernetes
Deployment supplies its non-root identity, offline settings and model path.
Only the downloader uses `Dockerfile.downloader` to install the required tools.
Existing immutable tags are reused. Choose a new engine tag when changing the
upstream image, or a new downloader tag when changing its Dockerfile/base.
Updating only the S3 model requires no image publication. The deployment resolves
both tags to digests. The mirrored engine is a single-platform manifest; its ECR
digest can differ from the upstream multi-platform index, and index-level
attestations are not copied by this flow. Review ECR scan results before promotion; the publisher does
not enforce a vulnerability acceptance policy.

The publishing machine needs internet access to pull Docker Hub images and install the
downloader's Linux packages. Docker login uses the normal credential store. Image
pulls in EKS use the node role; the pinned EKS module already attaches ECR read
permissions. vLLM does not receive ECR credentials or an image-pull Secret.

Publisher permissions: `ecr:GetAuthorizationToken` on `*`, and repository-scoped
`DescribeRepositories`, `DescribeImages`, `BatchCheckLayerAvailability`,
`InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, and
`BatchGetImage` ECR actions. Add further read actions only if a chosen Buildx feature
requires them. Keep publisher privileges separate from workload roles.

## Private access

The VPC stack creates:

| Endpoint | Type | Use |
| --- | --- | --- |
| `ecr.api` | Interface | Image authentication/API |
| `ecr.dkr` | Interface | Registry |
| `s3` | Gateway | ECR layers AND model archives |
| `sts` | Interface | Regional IRSA credential exchange |

Interface endpoints use private DNS and accept HTTPS from the private subnet CIDRs.
The shared S3 gateway endpoint covers all private route tables. Its default policy
preserves access to the AWS-managed ECR layer bucket and other IAM-authorized S3
resources. If tightening it, allow both ECR's regional layer bucket and your model
bucket. Endpoint policies alone do not grant IAM permissions.

Three interface services across the configured three AZs create nine endpoint
network interfaces, with recurring interface-endpoint charges. The gateway
endpoint has no additional endpoint charge. Other cluster components may still
need NAT/internet access for their own registries/services.

Continue with [models/README.md](../models/README.md) to publish a model and deploy.
No image builds, pushes or Terraform commands have been executed by the agent;
Docker is unavailable in the current environment. The tests directory remains absent.

References:

- [ECR endpoints and S3 layer routing](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)
- [Regional STS for IRSA](https://docs.aws.amazon.com/eks/latest/userguide/configure-sts-endpoint.html)
