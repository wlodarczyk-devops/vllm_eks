locals {
  labels = {
    app = "vllm"
  }

  # Built-in non-root user of the vllm/vllm-openai image (UID 2000, GID 0, home /home/vllm)
  run_as_user  = 2000
  run_as_group = 0
  home_dir     = "/home/vllm"

  # vLLM settings passed as container environment variables and referenced in args as $(NAME).
  # Prefix SERVE_ (not VLLM_): vLLM warns about, or with --fail-on-environ-validation rejects,
  # unknown VLLM_* variables, and VLLM_PORT / VLLM_HOST_IP are reserved for vLLM's internal use.
  serve_env = {
    SERVE_MODEL                  = var.model
    SERVE_HOST                   = var.host
    SERVE_PORT                   = tostring(var.port)
    SERVE_DTYPE                  = var.dtype
    SERVE_MAX_MODEL_LEN          = tostring(var.max_model_len)
    SERVE_GPU_MEMORY_UTILIZATION = tostring(var.gpu_memory_utilization)
  }
}

resource "kubernetes_namespace_v1" "vllm" {
  metadata {
    name = var.namespace

    # Pod Security Admission: reject pods that run as root, keep capabilities, use hostPath, ...
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
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
        # Don't inject Service env vars: the Service "vllm" would add VLLM_PORT=tcp://...,
        # which vLLM reads as its internal port and fails to start
        enable_service_links = false

        # vLLM never calls the Kubernetes API
        automount_service_account_token = false

        security_context {
          run_as_non_root = true
          run_as_user     = local.run_as_user
          run_as_group    = local.run_as_group
          fs_group        = local.run_as_group
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

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

          # Image entrypoint is `vllm serve`; Kubernetes replaces $(NAME) with the env values below
          args = [
            "$(SERVE_MODEL)",
            "--host", "$(SERVE_HOST)",
            "--port", "$(SERVE_PORT)",
            "--dtype", "$(SERVE_DTYPE)",
            "--max-model-len", "$(SERVE_MAX_MODEL_LEN)",
            "--gpu-memory-utilization", "$(SERVE_GPU_MEMORY_UTILIZATION)",
          ]

          dynamic "env" {
            for_each = local.serve_env
            content {
              name  = env.key
              value = env.value
            }
          }

          # Caches (Hugging Face, vLLM, Triton, torch.compile, CUDA) go under $HOME
          env {
            name  = "HOME"
            value = local.home_dir
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          # Probes and the Service target this named port, so changing var.port updates all of them
          port {
            name           = "http"
            container_port = var.port
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

          # Writable paths; the rest of the filesystem is read-only
          volume_mount {
            name       = "home"
            mount_path = local.home_dir
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
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

        # Pod-lifetime storage on the node disk: model files and caches are downloaded/rebuilt
        # on every pod start (hostPath isn't allowed by the "restricted" Pod Security Standard)
        volume {
          name = "home"
          empty_dir {
            size_limit = var.home_size
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = var.tmp_size
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
      port        = var.port
      target_port = "http"
    }
  }
}
