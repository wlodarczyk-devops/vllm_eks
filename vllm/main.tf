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
    # Recommended by llm-d: keep probe and metrics scrapes out of the access log
    SERVE_DISABLE_ACCESS_LOG_FOR_ENDPOINTS = "/health,/metrics,/v1/models"
    # Recommended by llm-d: on SIGTERM, reject new requests and let in-flight ones finish
    SERVE_SHUTDOWN_TIMEOUT = tostring(var.shutdown_timeout_seconds)
  }

  # Graceful shutdown (llm-d pattern): the pod leaves the Service/InferencePool during the
  # preStop sleep, then vLLM drains for shutdown_timeout_seconds, plus 15 s teardown buffer
  termination_grace_period_seconds = var.prestop_sleep_seconds + var.shutdown_timeout_seconds + 15
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
    replicas = var.replicas

    # Kubernetes marks a rollout as failed if a new pod isn't Ready within this time (default 600 s).
    # A pod on a new GPU node needs node scale-up + image pull + model load, which can exceed 10 min.
    progress_deadline_seconds = var.progress_deadline_seconds

    # One GPU per pod and no spare GPU: replace pods one at a time (stop one, start its
    # replacement) so the other replicas keep serving during an update
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 0
        max_unavailable = 1
      }
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

        termination_grace_period_seconds = local.termination_grace_period_seconds

        security_context {
          run_as_non_root = true
          run_as_user     = local.run_as_user
          run_as_group    = local.run_as_group
          fs_group        = local.run_as_group
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Prefer separate AZs without stranding a pod when only one AZ has GPU capacity.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = var.production_mode ? "DoNotSchedule" : "ScheduleAnyway"
          label_selector {
            match_labels = local.labels
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
          image = var.image_digest == null ? "vllm/vllm-openai:${var.vllm_version}" : "vllm/vllm-openai@${var.image_digest}"

          # Image entrypoint is `vllm serve`; Kubernetes replaces $(NAME) with the env values below
          args = concat([
            "$(SERVE_MODEL)",
            "--host", "$(SERVE_HOST)",
            "--port", "$(SERVE_PORT)",
            "--dtype", "$(SERVE_DTYPE)",
            "--max-model-len", "$(SERVE_MAX_MODEL_LEN)",
            "--gpu-memory-utilization", "$(SERVE_GPU_MEMORY_UTILIZATION)",
            "--disable-access-log-for-endpoints", "$(SERVE_DISABLE_ACCESS_LOG_FOR_ENDPOINTS)",
            "--shutdown-timeout", "$(SERVE_SHUTDOWN_TIMEOUT)",
          ], var.model_revision == null ? [] : ["--revision", var.model_revision, "--tokenizer-revision", var.model_revision])

          # Keep serving while the endpoint is removed from the Service/InferencePool
          lifecycle {
            pre_stop {
              exec {
                command = ["/bin/sleep", tostring(var.prestop_sleep_seconds)]
              }
            }
          }

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

          # The provider sends every bool field of this block, using false when unset, so
          # run_as_non_root must be set here too or it overrides the pod-level true
          security_context {
            run_as_non_root            = true
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
              cpu                 = var.cpu_request
              memory              = var.memory_request
              "ephemeral-storage" = var.ephemeral_storage_request
              "nvidia.com/gpu"    = 1
            }
            limits = {
              memory              = var.memory_limit
              "ephemeral-storage" = var.ephemeral_storage_limit
              "nvidia.com/gpu"    = 1
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
            timeout_seconds   = 3
            period_seconds    = 10
            failure_threshold = var.startup_timeout_seconds / 10
          }

          # Recommended by llm-d: ready only once the OpenAI API serves the model
          readiness_probe {
            http_get {
              path = "/v1/models"
              port = "http"
            }
            period_seconds  = 5
            timeout_seconds = 3
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            timeout_seconds   = 3
            period_seconds    = 10
            failure_threshold = 3
          }
        }

        # Pod-lifetime storage on the node disk: model files and caches are downloaded/rebuilt
        # whenever the pod is replaced (hostPath isn't allowed by the "restricted" Pod Security Standard)
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

  # How long `terraform apply` waits for the pod to become Ready
  timeouts {
    create = var.rollout_timeout
    update = var.rollout_timeout
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
