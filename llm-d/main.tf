locals {
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

# Gateway API Inference Extension CRD (InferencePool), vendored and pinned
resource "kubernetes_manifest" "crds" {
  for_each = {
    for m in provider::kubernetes::manifest_decode_multi(file("${path.module}/crds/gateway-api-inference-extension-${var.gaie_version}.yaml")) :
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
    file("${path.module}/values/optimized-baseline.values.yaml"),
    yamlencode(local.overrides),
  ]

  depends_on = [kubernetes_manifest.crds]
}
