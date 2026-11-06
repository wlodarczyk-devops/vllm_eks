# Versioned S3 model releases

The serving path uses a prepared Hugging Face snapshot in a private S3 bucket.
Terraform creates the bucket and streams the prepared files from disk using
`aws_s3_object`. It does not execute a provisioner or download models during plan.
The model bytes are not embedded in Terraform state; local source paths, checksums,
object versions and other resource metadata are recorded there.

```text
Pinned Hugging Face commit → local snapshot + SHA-256 manifest
    → Terraform uploads model files → publishes completion manifest
    → private, versioned S3 bucket
    → S3 gateway endpoint → download init container (read-only IRSA)
    → verify init container (no AWS token)
    → vLLM reads /models/model (read-only, offline, no AWS token)
```

The configured model is `Qwen/Qwen3-4B-Instruct-2507`, revision
`cdbee75f17c01a7cc42f958dc650907174af0554`. The revision was resolved from the
public Hugging Face model API on 2026-11-06. This establishes identity, not model
quality or a security certification. Retain its license and review artifacts
before promotion.

## What each part does

| Code | Purpose |
| --- | --- |
| `prepare_model.py` | Downloads the exact commit and prepares weights/tokenizer/configuration, excluding executable Python and pickle weight formats |
| `manifest.py` | Builds deterministic inventories and checks file sizes, SHA-256 hashes, shard completeness, duplicate paths and unexpected files |
| `main.tf` | Private bucket, disabled ACLs, public-access blocking, versioning, SSE-S3 encryption, TLS-only access and staged uploads |
| `outputs.tf` | Publishes one completed active release, including its expected manifest digest |
| `../vpc/s3-endpoint.tf` | Routes S3 traffic from every private route table through a gateway endpoint |
| `../vllm/model-storage.tf` | Exact service-account OIDC trust and endpoint-constrained read-only model access |
| `../vllm/main.tf` | Download/verify init containers, explicit STS token projection and offline model serving |

## Prepare the model

From the repository root, create a local virtual environment and install the
preparation dependency:

```bash
python3 -m venv .venv
.venv/bin/pip install -r model-store/requirements.txt
.venv/bin/python model-store/prepare_model.py
```

This downloads about 8 GB of model files. Allow additional working disk space for
Hub download metadata and temporary files. It creates:

```text
model-store/artifacts/qwen3-4b-2507/
├── manifest.json
└── files/  # safetensors weights, configuration, tokenizer and license
```

Artifacts and virtual environments are ignored by Git. The script refuses an
existing output directory to avoid stale artifacts being included in a new release.
For a failed preparation, use a fresh `--output` directory and update the release's
`directory` setting. You can pass `--model` and `--revision` explicitly; the revision
must be a complete commit. The preparation checks currently require the tokenizer
files used by Qwen, so review this logic before switching model families.

## Deployment order

No Terraform command, model download, upload, or AWS/Kubernetes mutation was run
while implementing this proposal. The commands below are for a later deployment.

1. Apply `vpc/` first, including the new S3 endpoint output. Existing private route
   tables gain an S3 prefix-list route; EKS nodes do not need to be recreated.
2. Prepare and review the local snapshot and manifest.
3. Apply `model-store/` to create the bucket and upload all objects. Keep this
   step in a trusted artifact-publishing environment with suitable disk/network
   capacity. Both plan and apply must have the same snapshot files available.
4. Create or retain the EKS cluster, including its OIDC provider.
5. Apply `vllm/` after the completed model-store state exists. It creates the reader
   role and ServiceAccount, downloads/verifies the release, and serves local files.
6. Deploy/use `llm-d/` as before. The API model name remains the Hugging Face ID,
   even though vLLM loads the weights from a local directory.

For example, after step 1 and preparation:

```bash
cd model-store
terraform init
terraform plan
terraform apply
cd ../vllm
terraform init
terraform plan
terraform apply
```

The bucket name is derived from cluster, account and region, for example
`vllm-eks-models-123456789012-eu-central-1`. Credentials come from the normal AWS
credential chain; no access keys or session tokens are in variables or state.
This stack follows the repository's local-state convention. Use a versioned,
locked remote backend before sharing it between operators.

## Permissions and trust

The runtime role grants only:

- `s3:GetObject` for the active release's manifest and files.
- `s3:ListBucket` on the artifact bucket, restricted to the active `files/` prefix.
- Both permissions require `aws:SourceVpce` to match this VPC's S3 endpoint.

The trust policy uses the exact cluster OIDC provider, subject
`system:serviceaccount:vllm:vllm-model-reader` (namespace follows the variable),
and audience `sts.amazonaws.com`. There are no bucket writes, deletes, AWS IAM,
EC2, EKS or KMS permissions on the reader role. SSE-S3 encryption avoids granting
runtime KMS access for public upstream artifacts. SSE-KMS can be introduced if a
customer-managed key is required, with `kms:Decrypt` scoped to that key and S3 use.

The ServiceAccount deliberately has no IRSA role annotation. AWS documents manual
IRSA configuration: the pod explicitly projects an STS-audience token and configures
the AWS SDK/CLI environment only in `download-model`. Automatic token mounting is
false. The verifier and serving containers mount neither the token nor AWS role
environment. This avoids the webhook injecting credentials into every container.
Kubernetes operators able to create pods using this ServiceAccount can still use
its role; restrict deployment and service-account usage accordingly.

The bucket additionally denies the model-reader role when requests do not use the
endpoint. This restriction is scoped to the reader identity so the external
Terraform publisher can still upload and inspect objects. The publisher needs
separate deployment permissions for bucket configuration and object uploads,
including multipart upload management. Never attach those privileges to vLLM or
llm-d. The policies do not grant cross-account sharing.

## Endpoint behavior

The gateway endpoint routes S3 traffic over the AWS network and avoids NAT data
processing for model downloads. S3 continues to use regional DNS names; a gateway
endpoint does not require interface endpoint private-DNS configuration or a
security group. The shared endpoint keeps its default policy to preserve other
S3 users, including ECR's layer bucket. That policy does not independently grant
S3 access: IAM and bucket policies still authorize each request.

STS credential exchange is separate from S3. The downloader uses regional STS,
which currently uses the existing NAT path. To remove that dependency, add an STS
interface endpoint with private DNS and appropriate security-group rules. Registry
image pulls have their own dependencies too.

If NetworkPolicies are added later, allow DNS, regional STS (or its interface
endpoint), and TCP 443 to S3's regional IP ranges. A gateway endpoint still uses
S3 destination addresses; a blanket block on non-RFC1918 addresses will break it.
Do not grant general model-server egress just to make downloads work.

## Integrity, retention and rollback

A release prefix contains the model ID, upstream commit, and manifest digest:
`models/<model-id>/<commit>/<manifest-sha256>/`. Every uploaded file gets an S3
SHA-256 checksum. The verifier independently checks the downloaded manifest against
the digest selected by Terraform state, then checks each file against that manifest.
Checksum mismatch or an unexpected file prevents vLLM from starting.

These prefixes are immutable by convention, not S3 Object Lock. A publishing
administrator with write permissions can replace objects; the serving verifier
will reject different bytes. Bucket versioning retains previous object versions.
Bucket/object `prevent_destroy` guards reject ordinary destructive plans while
those declarations remain present; do not remove the declarations to bypass them.
No automatic model-expiration lifecycle rule is configured. Incomplete multipart
uploads are cleaned after seven days.

To publish a new model revision:

1. Prepare it in a new local directory.
2. Add a NEW entry to `releases` in `terraform.tfvars`; retain the old entries and
   their local manifests/files. Do not modify the content of a published release.
3. Upload the new release first while keeping `active_release` unchanged.
4. Select the new active release and apply model-store, then vLLM.
5. For rollback, select a retained previous release and apply both stacks again.

Retaining old release entries prevents Terraform from deleting rollback artifacts.
The current reader role permits only the active release. During promotion, old
pods already serving local files continue to run, but restarting an old pod's init
container after the policy switches can fail until the new Deployment is applied.
For stricter availability, implement a bounded old/new-prefix overlap during the
rollout. The existing vLLM strategy also removes one replica before replacing it;
benchmark single-replica capacity before claiming zero downtime.

Each replacement pod downloads its own copy into `emptyDir`. A container restart
in the same pod preserves the volume. This avoids attaching a multi-AZ shared
filesystem for the current small deployment, but it is not a persistent model
cache. Larger fleets should evaluate node-local prewarming or a suitable shared
cache. GPU root disks remain 100 GiB; requests reserve 40 GiB of ephemeral space
and the serving limit is 55 GiB, in addition to image storage. Validate actual
peak disk usage and download/startup times. Init downloads happen BEFORE startup
probes begin; Deployment progress and rollout timeouts must include them.

## Validation

```bash
# Integrity tests use tiny fixtures, with no AWS or Hub requests.
python3 -m unittest discover -s tests -p test_model_artifacts.py -v
# All tests, including HCL/credential-isolation contracts:
python3 -m pip install python-hcl2==7.3.1
python3 -m unittest discover -s tests -v
```

Before promotion, verify role assumption in CloudTrail, successful S3 reads through
the endpoint, rejection of reads outside the prefix/endpoint, missing credentials
in the serving container, a real completion with the existing API model name, and
failure to start after deliberate corruption of a test release. Configure S3 data
event logging separately if object-level audit evidence is required.

Static checks do not replace Terraform provider validation or a live AWS/GPU test.
The implementation has not uploaded the real snapshot or run the init containers.

References:

- [Hugging Face snapshot preparation](https://huggingface.co/docs/huggingface_hub/en/guides/download)
- [S3 gateway endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)
- [Manual IRSA environment/token configuration](https://docs.aws.amazon.com/eks/latest/userguide/pod-configuration.html)
- [AWS CLI checksum verification](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html)
