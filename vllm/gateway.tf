variable "gateway" {
  description = "Optional private TLS/basic-auth gateway. Secrets must already exist; their values never enter Terraform state"
  type = object({
    enabled          = optional(bool, false)
    image            = optional(string, "nginxinc/nginx-unprivileged@sha256:7377697a821c131a924a7105fafbe7414db4e9fcc77a6f08f776f33f141ec3f8")
    replicas         = optional(number, 2)
    tls_secret_name  = optional(string, "inference-gateway-tls")
    auth_secret_name = optional(string, "inference-gateway-auth")
    client_namespace = optional(string, "llm-clients")
  })
  default = {}
  validation {
    condition     = var.gateway.replicas >= 1 && floor(var.gateway.replicas) == var.gateway.replicas
    error_message = "Gateway replicas must be a positive whole number."
  }
}

locals {
  gateway_labels = { app = "inference-gateway" }
}

data "kubernetes_service_v1" "dns" {
  count = var.gateway.enabled ? 1 : 0
  metadata {
    name      = "kube-dns"
    namespace = "kube-system"
  }
}

resource "kubernetes_config_map_v1" "gateway" {
  count = var.gateway.enabled ? 1 : 0
  metadata {
    name      = "inference-gateway"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/templates/gateway.conf.tftpl", {
      dns_resolver = data.kubernetes_service_v1.dns[0].spec[0].cluster_ip
      upstream     = "${var.router_release_name}-epp.${var.namespace}.svc.cluster.local:80"
    })
  }
}

resource "kubernetes_deployment_v1" "gateway" {
  count = var.gateway.enabled ? 1 : 0
  metadata {
    name      = "inference-gateway"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    replicas = var.gateway.replicas
    selector { match_labels = local.gateway_labels }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    template {
      metadata {
        labels = local.gateway_labels
        annotations = {
          "checksum/config" = sha256(kubernetes_config_map_v1.gateway[0].data["nginx.conf"])
        }
      }
      spec {
        automount_service_account_token  = false
        enable_service_links             = false
        termination_grace_period_seconds = 150
        security_context {
          run_as_non_root = true
          run_as_user     = 101
          run_as_group    = 101
          fs_group        = 101
          seccomp_profile { type = "RuntimeDefault" }
        }
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "nvidia.com/gpu.present"
                  operator = "DoesNotExist"
                }
              }
            }
          }
        }
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = var.production_mode ? "DoNotSchedule" : "ScheduleAnyway"
          label_selector { match_labels = local.gateway_labels }
        }
        container {
          name    = "gateway"
          image   = var.gateway.image
          command = ["nginx"]
          args    = ["-g", "daemon off;", "-c", "/etc/gateway/nginx.conf"]
          security_context {
            run_as_non_root            = true
            read_only_root_filesystem  = true
            allow_privilege_escalation = false
            capabilities { drop = ["ALL"] }
          }
          resources {
            requests = { cpu = "100m", memory = "64Mi", "ephemeral-storage" = "128Mi" }
            limits   = { memory = "128Mi", "ephemeral-storage" = "256Mi" }
          }
          port {
            name           = "https"
            container_port = 8443
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            timeout_seconds = 3
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            timeout_seconds = 3
          }
          lifecycle {
            pre_stop {
              exec { command = ["/bin/sh", "-c", "sleep 5; nginx -s quit -c /etc/gateway/nginx.conf"] }
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/gateway"
            read_only  = true
          }
          volume_mount {
            name       = "tls"
            mount_path = "/etc/gateway-tls"
            read_only  = true
          }
          volume_mount {
            name       = "auth"
            mount_path = "/etc/gateway-auth"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }
        volume {
          name = "config"
          config_map { name = kubernetes_config_map_v1.gateway[0].metadata[0].name }
        }
        volume {
          name = "tls"
          secret {
            secret_name  = var.gateway.tls_secret_name
            default_mode = "0440"
          }
        }
        volume {
          name = "auth"
          secret {
            secret_name  = var.gateway.auth_secret_name
            default_mode = "0440"
          }
        }
        volume {
          name = "tmp"
          empty_dir { size_limit = "128Mi" }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "gateway" {
  count = var.gateway.enabled ? 1 : 0
  metadata {
    name      = "inference-gateway"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    type     = "ClusterIP"
    selector = local.gateway_labels
    port {
      name        = "https"
      port        = 443
      target_port = "https"
    }
  }
}

resource "kubernetes_network_policy_v1" "gateway" {
  count = var.gateway.enabled ? 1 : 0
  metadata {
    name      = "inference-gateway"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    pod_selector { match_labels = local.gateway_labels }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = var.gateway.client_namespace } }
        pod_selector { match_labels = { "inference-client" = "true" } }
      }
      ports {
        port     = "8443"
        protocol = "TCP"
      }
    }
    egress {
      to {
        pod_selector { match_labels = { "llm-d-router-gateway" = "${var.router_release_name}-epp" } }
      }
      ports {
        port     = "8081"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "gateway" {
  count = var.gateway.enabled && var.gateway.replicas >= 2 ? 1 : 0
  metadata {
    name      = "inference-gateway"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    min_available = "1"
    selector { match_labels = local.gateway_labels }
  }
}
