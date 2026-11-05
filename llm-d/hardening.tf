variable "router_replicas" {
  description = "Active EPP/Envoy replicas; use two or more with multiple system nodes for production"
  type        = number
  default     = 1
  validation {
    condition     = var.router_replicas >= 1 && floor(var.router_replicas) == var.router_replicas
    error_message = "router_replicas must be a positive whole number."
  }
}

locals {
  # Verified against the v1.0.0 chart pod template, not its metadata labels.
  router_pod_labels = { "llm-d-router-gateway" = "${var.release_name}-epp" }
}

data "aws_vpc" "cluster" {
  id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
}

resource "kubernetes_pod_disruption_budget_v1" "router" {
  count = var.router_replicas >= 2 ? 1 : 0
  metadata {
    name      = "${var.release_name}-router"
    namespace = var.namespace
  }
  spec {
    min_available = "1"
    selector {
      match_labels = local.router_pod_labels
    }
  }
}

resource "kubernetes_network_policy_v1" "router" {
  metadata {
    name      = "${var.release_name}-router"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = local.router_pod_labels
    }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {
          match_labels = { app = "inference-gateway" }
        }
      }
      ports {
        port     = "8081"
        protocol = "TCP"
      }
    }
    egress {
      to {
        pod_selector {
          match_labels = var.model_server_labels
        }
      }
      ports {
        port     = tostring(var.model_server_port)
        protocol = "TCP"
      }
    }
    # EKS private API IPs rotate. Permit HTTPS to the VPC and Kubernetes service
    # CIDRs; do not grant general internet egress to the router.
    egress {
      to {
        ip_block {
          cidr = data.aws_vpc.cluster.cidr_block
        }
      }
      to {
        ip_block {
          cidr = data.aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}
