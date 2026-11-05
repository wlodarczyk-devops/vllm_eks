# Operating the hardened proposal

This branch is a code proposal, not an applied deployment. No Terraform command
was executed while implementing it. Read the migration notes before applying to
an existing cluster. The lab keeps its one system node and single NAT gateway.

## Deployment and migration order

1. Review cost and capacity. `examples/production/*.tfvars.example` contains
   per-stack overrides. Supply the corresponding file after that stack's existing
   tfvars. Do not rename these files to auto-load them across unrelated stacks.
2. Apply the EKS changes before serving changes: the VPC CNI needs network-policy
   enforcement. The dedicated IRSA role must be available to `kube-system:aws-node`.
   For a live cluster, stage this migration: first attach the new CNI identity
   while retaining node-role CNI permissions, verify new node/pod networking,
   then remove node-role CNI permissions. The final code declares the latter state.
3. Apply VPC changes for flow logging and, if selected, one NAT gateway per AZ.
   Flow-log storage is billed. Check account policies for log encryption/retention.
4. Deploy the vLLM namespace, model and network policies with the gateway disabled.
   Existing in-cluster callers will be blocked unless explicitly allowed. Operator
   port-forward access still works through the API server and remains an RBAC trust
   boundary; NetworkPolicy is not a restriction on privileged cluster operators.
5. Deploy llm-d. Its pod selector was checked against chart v1.0.0. The router's
   inbound serving port accepts only gateway pods in the same namespace. Pod-label
   creation rights in that namespace must therefore be restricted to operators.
6. Provision gateway credentials and certificates externally, then enable the
   gateway in the vLLM stack. No credential values are managed by Terraform.
7. Install the monitoring manifests into an existing Prometheus Operator setup,
   configure its selectors and alert receiver, then perform the acceptance checks.

The first vLLM deployment can precede llm-d because gateway DNS resolution happens
at request time. The gateway health probe checks nginx, not backend readiness;
use end-to-end synthetic inference to detect downstream outages.

## Gateway contract

The private ClusterIP service is `inference-gateway.vllm.svc.cluster.local:443`.
The gateway expects these pre-existing Secrets in the serving namespace:

| Secret | Keys | Purpose |
| --- | --- | --- |
| `inference-gateway-tls` | `tls.crt`, `tls.key` | Certificate chain and private key; certificate SAN must match the client hostname |
| `inference-gateway-auth` | `htpasswd` | A password file in an nginx-supported format, maintained by your secret-management process |

Use a trusted certificate issuer. Do not disable client certificate verification.
The client namespace defaults to `llm-clients`, and client pods must also have
`inference-client=true`. Namespace and pod selectors are combined with AND.
The gateway uses HTTP Basic authentication over TLS, not OpenAI Bearer-key auth.
Clients must supply the Basic Authorization header (or use a client adapter).
For workforce/tenant identity, replace this minimal boundary with your OIDC/JWT
API gateway; do not mistake static passwords for a full tenant authorization model.

Allowed requests are GET `/v1/models`, POST `/v1/chat/completions`, and POST
`/v1/completions`. Other paths return 404. Credentials and destination-routing
headers are removed before proxying. Prompt bodies, query strings and credentials
are excluded from access logs. Streaming response buffering and automatic retries
are disabled so a POST is not replayed against another backend.

Limits are deliberately simple: 1 MiB request bodies, 10 requests/second per
source IP with burst 20, and 8 concurrent requests/connections per source IP per
replica. These are not distributed tenant or token quotas. They may penalize NATed
clients and increase as replicas are added. The 120-second proxy read timeout is
an inactivity timeout, not a total request deadline. Add token-aware admission and
bounded total request duration in the application gateway before external use.

TLS ends at the gateway; router-to-model traffic remains HTTP within the restricted
namespace. Use mTLS if the threat model requires protection from node/network
administrators. Secret rotation must be followed by a controlled gateway rollout:
nginx does not automatically reload a changed certificate. Keep old credentials
valid during the overlap period.

## Network-policy boundaries

- Namespace default-deny applies to ingress and egress.
- DNS access is allowed only to CoreDNS in `kube-system`, TCP/UDP 53.
- Gateway ingress requires the trusted client namespace AND pod label, TCP 8443.
- Gateway egress permits the router on TCP 8081.
- Router egress permits model pods on the configured model port and HTTPS to the
  VPC/service CIDRs for the private Kubernetes API. The latter is deliberately
  broader than the changing control-plane IPs; tighten with platform-specific
  endpoint-aware policies where available.
- vLLM accepts the router and labelled Prometheus pods in `monitoring`.
  NetworkPolicy operates at L3/L4: Prometheus consequently reaches the whole vLLM
  HTTP port, not just `/metrics`. Treat monitoring as trusted or add a metrics proxy.
- Model download egress permits public TCP 443, excluding private, loopback and
  link-local destinations. This is NOT an FQDN allowlist and still permits HTTPS
  exfiltration. Trivy reports KUBE-0002 for this rule; it is not suppressed.
  Replace it with a controlled artifact mirror/egress proxy before handling
  sensitive production prompts under a strict egress policy.

VPC CNI standard enforcement mode is retained so enabling the feature does not
silently break CoreDNS or system add-ons. It has a policy-installation window for
new pods. Strict mode is a separate cluster-wide migration requiring policies for
all affected system workloads, not just the serving namespace.

## Availability and model lifecycle

Production examples add CPU capacity, a uniform GPU type, and two active router
replicas. EPP caches/load estimates remain local to each replica; test routing
quality under concurrent traffic. The router rolls with zero unavailable replicas
and one surge. Its zone anti-affinity is preferred, so inspect actual placement.
For stronger placement guarantees, reserve sufficient CPU capacity across AZs.

vLLM and the gateway use strict zone spreading in `production_mode`, and preferred
spreading in lab mode. Strict spreading can leave pods Pending during capacity
shortages; multi-AZ subnets alone do not guarantee GPU availability. Disruption
budgets protect voluntary evictions only. They do not protect against node/AZ
failure, direct deletion, or Deployment rollout replacement.

The vLLM rollout still uses `maxSurge=0`, `maxUnavailable=1`; one replica must handle
the service during updates. Raising the GPU maximum alone does not change that
strategy. Benchmark one-replica capacity or reserve surge capacity and deliberately
change the strategy. Cluster Autoscaler responds to pending pods, not request rate.
No workload autoscaler is added without a validated workload metric and SLO.

Image digests and the model/tokenizer commit were resolved from upstream metadata
on 2026-11-05. Resolution establishes identity, not provenance, vulnerability
clearance or hardware compatibility. Test on each supported GPU/driver combination
before promotion. Update the version tag and digest together for clear documentation.

`emptyDir` caches persist through container restarts, but are lost when a pod is
replaced. The 40 GiB ephemeral request reserves scheduler capacity, and the 45 GiB
limit includes model/temp data and logs. Image storage is additional node capacity.
`/dev/shm` is memory-backed and contributes to memory usage. A persistent cache is
not introduced automatically: storage topology, EBS CSI identity, access mode and
concurrent model loading need a separate design. The 100 GiB GPU disk still needs
real usage measurements and eviction alerts.

Shared GAIE CRDs now have `prevent_destroy`. Ordinary llm-d teardown therefore
fails safely rather than deleting all instances of these cluster-scoped types.
This is not protection if the resource declaration is removed entirely. Move
ownership to a dedicated platform stack using a reviewed state migration before
sharing the cluster with other InferencePools. Do not simply remove the guard and
destroy the CRD; that deletes its custom resources cluster-wide.

## Remote state migration

The backend remains local until an explicit migration. Conditional backend blocks
are not supported; an S3 example is provided rather than silently changing storage.
Local state has local locking but lacks shared remote locking/versioned recovery.

Provision a state bucket separately with versioning, encryption, public access
blocked, TLS-only access, and least-privilege IAM. Keep it outside the lifecycle of
these stacks. For each stack, review/copy `examples/state/backend.tf.example` and
prepare a local `backend.hcl` from the example, using a unique environment/stack key.
Use the normal AWS credential chain; never put credentials into backend files.

Freeze other writers, securely back up state, then run a deliberate backend
migration in a separate approved deployment session. Confirm resource addresses
and outputs against the old state before allowing writes. S3 native locking uses
`use_lockfile=true`; grant read/write access to the state object and read/write/delete
access to its `.tflock` object. Do not grant state-object deletion routinely.
Migrate the VPC first, then set EKS `vpc_state_backend=s3` and its backend coordinates.
Migrate the remaining stack states separately. Test versioned recovery without
replacing the live state. No migration has been performed by this branch.

## Validation and acceptance

Local static checks (no Terraform):

```bash
python -m pip install -r scripts/requirements-checks.txt
python scripts/check_repository.py
helm pull oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v1.0.0 --untar --untardir /tmp/router-review
python scripts/render_router.py /tmp/router-review/llm-d-router-standalone
python scripts/test_gateway.py  # requires a working Docker daemon and OpenSSL
```

The renderer handles the limited expressions used in the chart overrides; it does
not validate the full Terraform dependency graph or provider schema. The CI workflow
runs the parser/policy checks and disposable gateway test without cloud credentials.
It also gates on secret scanning and publishes an infrastructure security report;
the latter is report-only while the documented public-HTTPS exception remains.
It does not provision infrastructure. Enable that workflow as a required branch
check after the first successful run. Review the security report and separately scan serving images; the focused contract tests are not vulnerability scans.

Before promoting, verify:

1. Unauthorized clients cannot reach the router/model; missing or invalid gateway
   credentials return 401, disallowed paths 404, and oversized requests 413.
2. DNS, model downloads, EPP Kubernetes watches and metrics scraping succeed with
   policy enforcement active. A new node can join after the CNI identity migration.
3. Real streaming completions succeed through the TLS gateway and survive normal
   draining within the chosen request/shutdown limits.
4. A synthetic inference detects an unavailable model even when gateway probes pass.
5. Router/model node loss, AZ unavailability, voluntary drain and rolling updates
   meet measured recovery and availability targets.
6. Load tests cover prompt/output lengths, cold/warm prefix caches and each GPU
   class. Record p50/p95/p99 first-token latency, inter-token latency, throughput,
   errors, queued requests and cost per accepted request. Calibrate llm-d accordingly.
7. Monitoring selectors match actual resources, alert rules have real series,
   alerts reach an owner, and deliberate scale-to-zero is silenced appropriately.

## References

- [AWS VPC CNI policy enforcement](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html)
- [vLLM security boundaries](https://docs.vllm.ai/en/latest/usage/security/)
- [S3 state backend and locking](https://developer.hashicorp.com/terraform/language/backend/s3)
- [nginx Basic authentication](https://docs.nginx.com/nginx/admin-guide/security-controls/configuring-http-basic-authentication/)
- [Kubernetes port-forward selection](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
