locals {
  # llm-d's Optimized Baseline values without router.modelServers.matchLabels: its label
  # llm-d.ai/guide=optimized-baseline would be merged into our selector (Helm merges maps across
  # values files, and null doesn't remove a key set in another values file) and match no vLLM pod
  optimized_baseline = yamldecode(file("${path.module}/values/optimized-baseline.values.yaml"))
  optimized_baseline_values = merge(local.optimized_baseline, {
    router = merge(local.optimized_baseline.router, {
      modelServers = {
        for k, v in local.optimized_baseline.router.modelServers : k => v if k != "matchLabels"
      }
    })
  })

  # Pod Security "restricted": both router images already run as UID/GID 65532 (distroless nonroot)
  pod_security_context = {
    runAsNonRoot   = true
    runAsUser      = 65532
    runAsGroup     = 65532
    seccompProfile = { type = "RuntimeDefault" }
  }

  container_security_context = {
    runAsNonRoot             = true
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    capabilities             = { drop = ["ALL"] }
  }

  # Overrides on top of llm-d's recommended values (values/*.yaml) for this cluster
  overrides = {
    router = {
      # InferencePool: select the existing vLLM pods of the vllm/ stack
      modelServers = {
        matchLabels = var.model_server_labels
        targetPorts = [{ number = var.model_server_port }]
      }

      epp = {
        podSecurityContext = local.pod_security_context
        securityContext    = local.container_security_context

        # Run on the CPU system node, never on a GPU node
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [{
                matchExpressions = [{ key = "nvidia.com/gpu.present", operator = "DoesNotExist" }]
              }]
            }
          }
        }

        # Recommended 4 CPU / 8 GiB is sized for production traffic; scaled down for the PoC
        resources = {
          requests = { cpu = var.epp_cpu_request, memory = var.epp_memory_request }
          limits   = { memory = var.epp_memory_limit }
        }
      }

      proxy = {
        securityContext = local.container_security_context

        resources = {
          requests = { cpu = var.proxy_cpu_request, memory = var.proxy_memory_request }
          limits   = { memory = var.proxy_memory_limit }
        }

        # Recommended Envoy args, with --concurrency matched to the scaled-down CPU
        args = [
          "--service-node", "envoy-sidecar",
          "--log-level", "warn",
          "--concurrency", tostring(var.proxy_concurrency),
          "--drain-strategy", "immediate",
          "--drain-time-s", "60",
          "-c", "/etc/envoy/envoy.yaml",
        ]
      }
    }
  }
}

# Gateway API Inference Extension CRDs (InferencePool) from the pinned release; the checksum
# makes sure exactly the reviewed file is applied
data "http" "gaie_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${var.gaie_version}/v1-manifests.yaml"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && sha256(self.response_body) == var.gaie_manifest_sha256
      error_message = "Download of the GAIE ${var.gaie_version} CRDs failed or its SHA-256 doesn't match gaie_manifest_sha256."
    }
  }
}

resource "kubernetes_manifest" "crds" {
  for_each = {
    for m in provider::kubernetes::manifest_decode_multi(data.http.gaie_crds.response_body) :
    m.metadata.name => m
  }

  # The upstream file includes "status", which is set by the API server and not allowed here
  manifest = { for k, v in each.value : k => v if k != "status" }
}

# llm-d Router in Standalone Mode: EPP + Envoy sidecar in one pod, plus the InferencePool
resource "helm_release" "router" {
  name       = var.release_name
  namespace  = var.namespace
  repository = "oci://ghcr.io/llm-d/charts"
  chart      = "llm-d-router-standalone"
  version    = var.router_chart_version

  # Later files override earlier ones: llm-d base → Optimized Baseline → this cluster
  values = [
    file("${path.module}/values/base.values.yaml"),
    yamlencode(local.optimized_baseline_values),
    yamlencode(local.overrides),
  ]

  depends_on = [kubernetes_manifest.crds]
}
