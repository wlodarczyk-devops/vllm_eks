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
    SERVE_MODEL                  = "/models/model"
    SERVE_MODEL_NAME             = var.model
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
        service_account_name            = kubernetes_service_account_v1.vllm.metadata[0].name

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

        # Explicit IRSA projection confines AWS identity to this init container.
        init_container {
          name    = "download-model"
          image   = "${data.aws_ecr_repository.vllm.repository_url}@${data.aws_ecr_image.downloader.image_digest}"
          command = ["/bin/sh", "-ec"]
          args = [<<-SCRIPT
            aws s3api get-object --bucket "$MODEL_BUCKET" --key "$MODEL_KEY" --version-id "$MODEL_VERSION" --checksum-mode ENABLED /download/model.tar.gz >/dev/null
            printf '%s  %s\n' "$MODEL_SHA256" /download/model.tar.gz | sha256sum -c -
            mkdir -p /models/model
            tar -xzf /download/model.tar.gz -C /models/model --no-same-owner --no-same-permissions
            test -s /models/model/config.json
            test -s /models/model/tokenizer_config.json
            rm -f /download/model.tar.gz
          SCRIPT
          ]
          env {
            name  = "MODEL_BUCKET"
            value = data.aws_s3_bucket.models.id
          }
          env {
            name  = "MODEL_KEY"
            value = local.model_release.key
          }
          env {
            name  = "MODEL_VERSION"
            value = coalesce(local.model_release.version_id, "UNPUBLISHED")
          }
          env {
            name  = "MODEL_SHA256"
            value = coalesce(local.model_release.sha256, "UNPUBLISHED")
          }
          env {
            name  = "AWS_ROLE_ARN"
            value = aws_iam_role.model_reader.arn
          }
          env {
            name  = "AWS_WEB_IDENTITY_TOKEN_FILE"
            value = "/var/run/model-identity/token"
          }
          env {
            name  = "AWS_DEFAULT_REGION"
            value = var.region
          }
          env {
            name  = "AWS_REGION"
            value = var.region
          }
          env {
            name  = "AWS_STS_REGIONAL_ENDPOINTS"
            value = "regional"
          }
          env {
            name  = "AWS_EC2_METADATA_DISABLED"
            value = "true"
          }
          env {
            name  = "HOME"
            value = "/download"
          }
          env {
            name  = "AWS_PAGER"
            value = ""
          }
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          resources {
            requests = { cpu = "250m", memory = "256Mi", "ephemeral-storage" = "20Gi" }
            limits   = { memory = "1Gi", "ephemeral-storage" = "35Gi" }
          }
          volume_mount {
            name       = "model"
            mount_path = "/models"
          }
          volume_mount {
            name       = "model-download"
            mount_path = "/download"
          }
          volume_mount {
            name       = "model-identity"
            mount_path = "/var/run/model-identity"
            read_only  = true
          }
        }

        container {
          name  = "vllm"
          image = "${data.aws_ecr_repository.vllm.repository_url}@${data.aws_ecr_image.vllm.image_digest}"

          # Image entrypoint is `vllm serve`; Kubernetes replaces $(NAME) with the env values below
          args = [
            "$(SERVE_MODEL)",
            "--served-model-name", "$(SERVE_MODEL_NAME)",
            "--host", "$(SERVE_HOST)",
            "--port", "$(SERVE_PORT)",
            "--dtype", "$(SERVE_DTYPE)",
            "--max-model-len", "$(SERVE_MAX_MODEL_LEN)",
            "--gpu-memory-utilization", "$(SERVE_GPU_MEMORY_UTILIZATION)",
            "--disable-access-log-for-endpoints", "$(SERVE_DISABLE_ACCESS_LOG_FOR_ENDPOINTS)",
            "--shutdown-timeout", "$(SERVE_SHUTDOWN_TIMEOUT)",
          ]

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

          # The init container prepares local weights/tokenizer; serving stays offline.
          env {
            name  = "HF_HUB_OFFLINE"
            value = "1"
          }
          env {
            name  = "TRANSFORMERS_OFFLINE"
            value = "1"
          }
          env {
            name  = "AWS_EC2_METADATA_DISABLED"
            value = "true"
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
              "ephemeral-storage" = "40Gi"
              "nvidia.com/gpu"    = 1
            }
            limits = {
              memory              = var.memory_limit
              "ephemeral-storage" = "55Gi"
              "nvidia.com/gpu"    = 1
            }
          }

          volume_mount {
            name       = "model"
            mount_path = "/models"
            read_only  = true
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

          # Covers engine load/warm-up after image pulls and model preparation
          startup_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds    = 10
            failure_threshold = var.startup_timeout_seconds / 10
          }

          # Recommended by llm-d: ready only once the OpenAI API serves the model
          readiness_probe {
            http_get {
              path = "/v1/models"
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

        volume {
          name = "model"
          empty_dir { size_limit = "15Gi" }
        }
        volume {
          name = "model-download"
          empty_dir { size_limit = "15Gi" }
        }
        volume {
          name = "model-identity"
          projected {
            sources {
              service_account_token {
                audience           = "sts.amazonaws.com"
                expiration_seconds = 3600
                path               = "token"
              }
            }
          }
        }

        # Runtime caches survive container restarts but are lost on pod replacement.
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

  lifecycle {
    precondition {
      condition     = var.model == local.model_release.model_id
      error_message = "model must match models/release.json."
    }
    precondition {
      condition     = try(length(local.model_release.version_id) > 0, false) && can(regex("^[0-9a-f]{64}$", local.model_release.sha256))
      error_message = "Publish the model first: models/release.json must contain its S3 version_id and SHA-256."
    }
  }
  depends_on = [aws_iam_role_policy.model_reader]

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
