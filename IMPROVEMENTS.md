# S3 model artifact improvements

Scope: `feature/s3-model-artifacts`. This branch supplies deployment code; no AWS
resources, model uploads or Kubernetes changes have been applied by the agent.
See [the operating guide](model-store/README.md) for preparation and deployment.

| What changed | Change code | Purpose | What could be next |
| --- | --- | --- | --- |
| Private, encrypted, versioned artifact bucket | [`model-store/main.tf`](model-store/main.tf): public access blocked, ACLs disabled, SSE-S3, TLS-only policy, destruction guards | Store weights separately from serving nodes and retain recoverable versions | Remote state, object-level audit events, optional customer-managed KMS encryption |
| Pinned model preparation and Terraform uploads | [`prepare_model.py`](model-store/prepare_model.py), `aws_s3_object.files` and `aws_s3_object.manifest` | Upload the configured Qwen snapshot from a full upstream commit; publish a completion manifest after all files | Trusted artifact-publishing CI, artifact signing and malware/provenance checks |
| Checksummed release identity and local verification | [`manifest.py`](model-store/manifest.py), content-addressed S3 prefixes, `verify-model` init container | Reject changed manifests, corrupted/missing weights, unexpected files and path traversal before serving | Benchmark verification/startup latency; retain signed release evidence |
| S3 gateway endpoint | [`vpc/s3-endpoint.tf`](vpc/s3-endpoint.tf), VPC endpoint output | Route model transfers from private subnets without NAT data processing | STS interface endpoint if private credential exchange is needed; carefully scoped shared endpoint policy |
| Read-only, endpoint-scoped IRSA | [`vllm/model-storage.tf`](vllm/model-storage.tf) | Allow only the active release's object reads and file-prefix listing, with exact cluster/service-account/audience trust | Verify CloudTrail role assumptions and negative-access cases after deployment |
| AWS identity restricted to the downloader | Explicit projected token and environment in [`vllm/main.tf`](vllm/main.tf) | Keep the verifier and serving process free of mounted AWS credentials and Kubernetes API tokens | Admission policies restricting who may deploy with this ServiceAccount; runtime network isolation |
| Offline local serving with stable API name | Init download/verification, read-only model mount, `--served-model-name`, offline environment, disk reservations | Serve from verified artifacts while preserving llm-d/client model selection | Node-local prewarming or persistent caches for larger fleets; GPU and disk capacity tests |
| Release retention and rollback guidance | `releases`/`active_release`, destruction guards, [`model-store/README.md`](model-store/README.md) | Keep previous declared releases while promoting a selected release | Bounded old/new reader-policy overlap for stricter rollout availability; controlled artifact retirement |
