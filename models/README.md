# Model weights in S3, engine in ECR

The S3 bucket stores one versioned model archive per release. One init container
downloads its exact S3 version, checks SHA-256, extracts it into a local volume,
and exits. vLLM reads that volume read-only and serves offline. The model and engine
can be promoted independently.

```text
Private ECR → kubelet → vLLM and downloader images
Private STS endpoint → downloader's temporary IRSA credentials
S3 archive version → S3 gateway endpoint → init container
    → checksum/extract → read-only local model → vLLM → llm-d
```

Terraform creates infrastructure/permissions; the publisher uploads artifacts.
No weight file is an individual Terraform resource, and no provisioner performs
hidden downloads. `release.json` selects the upstream commit, S3 key, exact object
version and archive checksum. Its version/checksum start as null and deployment
is blocked until publication fills them in.

## Deployment order

1. Apply `vpc/`, creating ECR, S3 and STS endpoints. Create/retain EKS and its OIDC
   provider as usual.
2. Create/publish the engine and downloader images using [ecr/README.md](../ecr/README.md).
3. Create the private model bucket in a deployment session:

   ```bash
   cd models
   terraform init
   terraform apply
   cd ..
   ```

4. Prepare and publish the selected model from a trusted machine with AWS CLI:

   ```bash
   python3 -m venv .venv
   .venv/bin/pip install -r models/requirements.txt
   .venv/bin/python models/publish.py --region eu-central-1 --bucket YOUR_BUCKET_NAME
   ```

   Use the `bucket_name` output of the models stack. The default name is
   `vllm-eks-models-ACCOUNT_ID-eu-central-1`. The publisher downloads the pinned
   Qwen snapshot, builds an archive and uses multipart upload for large objects.
   Allow approximately 25 GiB of free temporary disk space and download/upload
   time. Publishing requires internet access to Hugging Face; GPU pods do not.

5. Review and commit the updated `models/release.json`, including the version ID
   and SHA-256. Review image scans, then plan/apply `vllm/`. It discovers the ECR
   repository, S3 bucket and S3 endpoint through AWS APIs, with no cross-stack
   local-state dependency for these resources. Use llm-d as before.

Only the selected Qwen-style config/tokenizer and safetensors files are packaged,
including the license. Executable model code and pickle weights are excluded.
The configured upstream commit is `cdbee75f17c01a7cc42f958dc650907174af0554` for
`Qwen/Qwen3-4B-Instruct-2507`. Review the artifacts/license before promotion.

## Identity and data protection

- The bucket blocks public access, disables ACLs, enables versioning and SSE-S3
  encryption, and denies insecure transport. Bucket deletion is guarded. Old
  object versions are retained; only incomplete multipart uploads are cleaned.
- The reader role permits only `s3:GetObjectVersion` for the selected archive ARN,
  conditioned on the selected `s3:VersionId` AND this VPC's S3 gateway endpoint.
  No bucket listing, writes, deletes or KMS permissions are granted.
- Its trust is restricted to this cluster's OIDC provider, exact subject
  `system:serviceaccount:<namespace>:vllm`, and audience `sts.amazonaws.com`.
- The pod explicitly projects the STS token only into `download-model`, with role
  environment only in that container. The ServiceAccount is not role-annotated,
  avoiding automatic webhook injection into the serving container. Automatic
  Kubernetes API token mounting remains disabled. No Kubernetes RoleBindings are
  added. AWS supports manually configured IRSA token/environment projection.
- Regional STS uses the private interface endpoint; S3 uses the gateway endpoint.
  The serving process mounts the extracted model read-only, with offline mode and
  no mounted AWS token. Restrict who may deploy pods using the ServiceAccount.

The publishing identity separately needs `s3:GetBucketVersioning`, `s3:ListBucket`
on this bucket (for missing-key preflight checks), and `s3:PutObject`,
`s3:GetObject`, `s3:AbortMultipartUpload` on its model prefix. No deletion is needed.
Infrastructure provisioning needs its own bucket/IAM administration permissions.
The publisher is permitted to upload from outside the VPC; the runtime role's
read grant requires the S3 endpoint. SSE-KMS can be added later with scoped key
permissions if organizational policy requires a customer-managed key.

## Updates, rollback and limits

For a new model release, set the new upstream commit and a NEW S3 key in
`release.json`, reset `version_id`/`sha256` to null, then publish. The publisher
refuses an existing key and atomically updates the release file after checking the
uploaded version/metadata. If upload completed but the local update was lost,
inspect the object's version and SHA metadata before deliberately recovering the
release file; do not blindly overwrite it.

For rollback, restore the prior release file and apply vLLM. Keep old S3 versions
and tagged images until they are no longer needed. Selected S3 versions plus the
pinned SHA protect serving from later overwrites of a key; this is not S3 Object
Lock, and an administrator can still delete a selected version.

The reader policy allows one version at a time. Existing pods serving extracted
files continue to run after a policy update, but restarting an OLD init container
can fail once access switches. For stricter rollout availability, introduce a
bounded old/new-version permission overlap. The current rollout also removes one
GPU replica before replacing it; measure capacity and startup time accordingly.

Each new pod downloads a fresh archive into `emptyDir`; container restarts preserve
existing files. The archive is checked before extraction and removed afterward.
No separate verifier container or persistent filesystem is required. For larger
fleets, introduce persistent caching after measuring cold-start behavior.

The downloader needs space for both archive and extracted weights during startup.
Two 15 GiB volumes cover those paths for this 4B model; runtime caches are separate.
The serving pod reserves 40 GiB ephemeral storage with a 55 GiB limit, and the node
also needs room for image layers. Init download/extraction happens BEFORE startup
probes; Deployment progress and rollout timeouts include it.

If adding NetworkPolicies, allow the downloader's DNS, regional STS endpoint and
S3 HTTPS traffic. Gateway endpoints still use regional S3 destination addresses;
do not block all non-RFC1918 addresses. Kubelet image pulls follow node networking.

## Validation status

No automated tests directory is included. HCL, JSON, Python syntax and publishing
CLI help have been checked locally. No Terraform commands, model downloads/uploads,
image builds/pushes or live GPU serving checks were executed. Before promotion,
verify provider schemas/graph, both private image pulls, STS role assumption,
endpoint-constrained exact-version reads, checksum rejection and a real completion.

Earlier applied proposals require a reviewed migration. Do not remove an existing
bucket or model version merely because a previous stack path changed. Use the
normal state/import process for an existing matching bucket before applying this
new stack, and retain artifacts until the replacement deployment is working.

References:

- [Version-scoped S3 access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/amazon-s3-policy-keys.html)
- [Manual IRSA configuration](https://docs.aws.amazon.com/eks/latest/userguide/pod-configuration.html)
