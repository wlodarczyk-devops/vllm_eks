variable "router_release_name" {
  description = "Must match llm-d/release_name; the chart labels its EPP pods with this release"
  type        = string
  default     = "llm-d"
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$", var.router_release_name))
    error_message = "Router release must be a lowercase DNS label of at most 40 characters (chart naming limit)."
  }
}

variable "monitoring_namespace" {
  description = "Trusted namespace permitted to scrape model metrics"
  type        = string
  default     = "monitoring"
}

# Admission restrictions protect processes; network policies protect communication.
# The EKS stack enables VPC CNI policy enforcement before this namespace is deployed.
resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "dns" {
  metadata {
    name      = "allow-cluster-dns"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "vllm" {
  metadata {
    name      = "vllm-serving"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {
          match_labels = { "llm-d-router-gateway" = "${var.router_release_name}-epp" }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.monitoring_namespace }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "prometheus" }
        }
      }
      ports {
        port     = tostring(var.port)
        protocol = "TCP"
      }
    }
    # Hugging Face uses changing CDN addresses. This deliberately permits public
    # HTTPS, not an FQDN allowlist. Replace with controlled artifact egress later.
    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8"]
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}
