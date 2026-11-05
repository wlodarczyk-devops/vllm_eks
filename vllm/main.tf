locals {
  labels = {
    app = "vllm"
  }
}

resource "kubernetes_namespace_v1" "vllm" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_deployment_v1" "vllm" {
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = 1

    # One GPU per node: stop the old pod before starting the new one
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Run only on the GPU node group
        node_selector = {
          "nvidia.com/gpu.present" = "true"
        }

        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "vllm"
          image = "vllm/vllm-openai:${var.vllm_version}"

          # Image entrypoint is `vllm serve`
          args = [
            var.model,
            "--dtype", var.dtype,
            "--max-model-len", tostring(var.max_model_len),
            "--gpu-memory-utilization", tostring(var.gpu_memory_utilization),
          ]

          port {
            name           = "http"
            container_port = 8000
          }

          resources {
            requests = {
              cpu              = var.cpu_request
              memory           = var.memory_request
              "nvidia.com/gpu" = 1
            }
            limits = {
              memory           = var.memory_limit
              "nvidia.com/gpu" = 1
            }
          }

          volume_mount {
            name       = "hf-cache"
            mount_path = "/root/.cache/huggingface"
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          # Allows time for image pull, model download and load before liveness kicks in
          startup_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds    = 10
            failure_threshold = var.startup_timeout_seconds / 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds = 5
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }

        # Node-local model cache: survives pod restarts, re-downloaded only on a new node
        volume {
          name = "hf-cache"
          host_path {
            path = var.model_cache_host_path
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = var.shm_size
          }
        }
      }
    }
  }

  timeouts {
    create = "${var.startup_timeout_seconds / 60 + 5}m"
    update = "${var.startup_timeout_seconds / 60 + 5}m"
  }
}

resource "kubernetes_service_v1" "vllm" {
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
    labels    = local.labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.labels

    port {
      name        = "http"
      port        = 8000
      target_port = "http"
    }
  }
}
