# Infrastructure improvement proposal

Implemented on `feature/llm-infrastructure-hardening`. These are repository changes,
not deployed changes. Lab capacity is preserved; production overrides are explicit.
Read [operations and migration guidance](docs/OPERATIONS.md) before deployment.

| What changed | Change code | Purpose | What could be next |
| --- | --- | --- | --- |
| Enabled VPC CNI network-policy support | [`eks/main.tf`](eks/main.tf): `enableNetworkPolicy = "true"` | Make Kubernetes NetworkPolicies enforceable | Validate enforcement on new/existing pods; plan strict-mode migration for system workloads |
| Isolated serving traffic | [`vllm/network.tf`](vllm/network.tf), [`llm-d/hardening.tf`](llm-d/hardening.tf): default-deny plus explicit ingress/egress | Prevent ordinary workloads from bypassing the serving boundary; restrict model/router network access | Controlled artifact egress; narrow API access; a separate metrics proxy |
| Added an optional authenticated TLS gateway | [`vllm/gateway.tf`](vllm/gateway.tf), [`gateway.conf.tftpl`](vllm/templates/gateway.conf.tftpl): external Secret mounts, private Service, exact API routes | Protect inference access and avoid exposing administrative endpoints; keep secrets out of state | OIDC/JWT, tenant authorization, distributed token budgets and backend mTLS |
| Added request safeguards | Gateway template: 1 MiB bodies, per-IP request/concurrency limits, timeout settings, no automatic upstream retries | Bound simple abuse and avoid accidental duplicate inference; preserve streaming | Measure limits under real load; total request deadlines and per-tenant token-aware admission |
| Separated CNI AWS permissions | [`eks/hardening.tf`](eks/hardening.tf): dedicated `aws-node` IRSA; [`eks/main.tf`](eks/main.tf): node CNI policy attachment disabled | Reduce node-role blast radius | Stage the live migration and test replacement nodes before removing old permissions |
| Made administrative access explicit | EKS `access_entries` and `enable_cluster_creator_admin_permissions`; CIDR validation | Support named operator roles and reject accidental worldwide API CIDRs | Verify least-privilege roles and emergency access, then disable creator admin; private administration |
| Made existing audit controls explicit | [`eks/main.tf`](eks/main.tf): all five control-plane logs, 90-day retention, private endpoint | Preserve useful module defaults and improve incident evidence | Central log collection, alerting, retention policy and customer-managed log keys if required |
| Enabled VPC flow logs | [`vpc/main.tf`](vpc/main.tf): CloudWatch flow logs, 30-day retention | Provide network-level investigation evidence | Retention/cost tuning, centralized collection and detection rules |
| Added remote-state migration code | [`examples/state`](examples/state), EKS `vpc_state_backend`/`vpc_remote_state_config` | Provide S3 locking/encryption configuration and allow EKS to consume migrated VPC state | Provision a protected versioned bucket; perform and verify a deliberate state migration |
| Pinned serving artifacts | [`vllm/terraform.tfvars`](vllm/terraform.tfvars), [`vllm/main.tf`](vllm/main.tf), gateway image: digest and model/tokenizer commit | Make replacement pods use the same artifacts | Scan/sign/mirror artifacts; verify GPU compatibility; promote a tested rollback set |
| Added production preconditions | [`vllm/hardening.tf`](vllm/hardening.tf): `production_mode` checks immutable artifacts, gateway and replica counts | Prevent incomplete production overrides from silently retaining unpinned images or disabling auth | Organization-wide policy and validated SLOs; this flag is not certification |
| Added disruption budgets and placement | vLLM/gateway PDBs and zone spreading; router PDB and preferred zone anti-affinity | Reduce simultaneous voluntary disruption and improve fault separation | Enforce placement against reserved multi-AZ capacity; benchmark single-replica service during rollouts |
| Added router HA configuration | [`llm-d/main.tf`](llm-d/main.tf): configurable replicas, `haMode = "all-active"`, rolling updates | Keep multiple EPP replicas Ready rather than creating unready leader-election standbys | Measure per-replica cache divergence; assess coordinated routing state if necessary |
| Provided explicit production sizing | [`examples/production`](examples/production): multiple CPU nodes, homogeneous GPU pool, two routers, per-AZ NAT | Make reliability/cost choices reviewable without silently increasing lab capacity | Quota/capacity planning, capacity reservations, failure testing and cost budgets |
| Reserved ephemeral storage | [`vllm/main.tf`](vllm/main.tf): 40 GiB request / 45 GiB limit | Account for model/cache/log storage in scheduling and eviction decisions | Measure peak use; design immutable pre-staged or persistent caches with AZ-aware storage |
| Improved probes and input validation | vLLM 3-second probe timeouts; validated counts, GPU memory fraction, context length, startup budget and autoscaler version | Catch invalid settings early and reduce overly sensitive probes | Runtime tuning under saturation; verify shutdown budgets against long streams |
| Protected shared CRDs from ordinary teardown | [`llm-d/main.tf`](llm-d/main.tf): `prevent_destroy = true` | Avoid accidentally deleting every instance of a shared CRD during router teardown | Move CRDs to platform ownership with a reviewed state migration |
| Made tracing intent explicit | Router `tracing.enabled = false` | Avoid depending on inherited chart behavior until a collector exists | Deploy an OTLP collector, secure its traffic, then enable sampling; chart tracing was already disabled by default |
| Added monitoring integration and alerts | [`monitoring/vllm.yaml`](monitoring/vllm.yaml): ServiceMonitor and PrometheusRule | Collect model metrics and define initial availability/queue/latency signals | Install/operator-select these resources; configure Alertmanager, dashboards, GPU telemetry, log collection and missing-series alerts |
| Added CI and regression checks | [`infrastructure-checks.yml`](.github/workflows/infrastructure-checks.yml), [`scripts`](scripts): HCL/YAML parsing, policy contracts, chart renderer, gateway integration test, secret scan and infrastructure report | Make regressions reviewable without cloud credentials or Terraform execution | Require CI; add provider-aware validation in an authorized session, image scans and workload benchmarks |
| Pinned GitHub Actions | Both workflows use verified commit SHAs; checkout does not persist credentials | Reduce mutable-action supply-chain exposure | Automated reviewed dependency updates and review of the AI action's permissions |
| Corrected routing-test documentation | [`llm-d/README.md`](llm-d/README.md): in-cluster Service comparison | Avoid treating a port-forward pinned to one pod as a Service load-balancing test | Reproducible concurrent benchmarks with realistic connection reuse |
| Clarified cache lifetime and residual risk | README updates and [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | Distinguish pod replacement from container restart; document activation, migration and limits | Persistent cache design, controlled egress and operational acceptance testing |

## Validation performed

- Eight offline repository syntax/security-contract tests passed.
- The actual llm-d v1.0.0 chart rendered 13 resources with two active replicas and
  a non-default release name; selectors, model pool, security contexts, rolling
  strategy and disabled tracing checks passed.
- HCL formatted with HashiCorp's standalone `hclfmt`; no Terraform executable used.
- Trivy 0.75.0 scanned all four stacks with their tfvars and embedded checks,
  excluding findings inside downloaded modules. One HIGH finding remains:
  **KUBE-0002**, public HTTPS model-download egress in `vllm/network.tf`.
  It is deliberately documented and not suppressed. The operator public CIDR is
  supplied at deployment time and therefore was unknown to the scanner.
- Docker was unavailable locally. The gateway integration test is included in CI
  but has not run locally. TLS/authentication behavior must pass that test before
  promotion. Chart rendering is not provider-schema or Terraform graph validation.
- No Terraform, AWS mutation, Kubernetes mutation, state migration or deployment
  was performed during implementation.

## Remaining production work

This branch does not install a complete monitoring platform, implement OIDC or
per-tenant token quotas, add mTLS, persist model caches, calibrate the router,
introduce workload autoscaling, or promise an SLO. Those require deployment-specific
identity, storage, traffic and operational decisions. The table identifies each
follow-up rather than treating configuration scaffolding as a deployed control.
