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
        annotations = {
          "checksum/model-verifier" = sha256(kubernetes_config_map_v1.model_verifier.data["manifest.py"])
        }
      }

      spec {
        # Don't inject Service env vars: the Service "vllm" would add VLLM_PORT=tcp://...,
        # which vLLM reads as its internal port and fails to start
        enable_service_links = false

        # vLLM never calls the Kubernetes API
        automount_service_account_token = false
        service_account_name            = kubernetes_service_account_v1.model_reader.metadata[0].name

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

        # Only this container receives an STS token and AWS role environment.
        init_container {
          name    = "download-model"
          image   = var.model_downloader_image
          command = ["/bin/sh", "-ec"]
          args = [<<-SCRIPT
            aws s3 cp "$MODEL_MANIFEST_URI" /models/manifest.json --checksum-mode ENABLED --only-show-errors
            aws s3 sync "$MODEL_FILES_URI" /models/model/ --checksum-mode ENABLED --delete --only-show-errors
          SCRIPT
          ]
          env {
            name  = "MODEL_MANIFEST_URI"
            value = "s3://${local.stored_model.bucket}/${local.stored_model.prefix}/manifest.json"
          }
          env {
            name  = "MODEL_FILES_URI"
            value = "s3://${local.stored_model.bucket}/${local.stored_model.prefix}/files/"
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
            name  = "AWS_REGION"
            value = var.region
          }
          env {
            name  = "AWS_DEFAULT_REGION"
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
            value = "/tmp"
          }
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          resources {
            requests = { cpu = "250m", memory = "256Mi", "ephemeral-storage" = "12Gi" }
            limits   = { memory = "1Gi", "ephemeral-storage" = "20Gi" }
          }
          volume_mount {
            name       = "model"
            mount_path = "/models"
          }
          volume_mount {
            name       = "model-identity"
            mount_path = "/var/run/model-identity"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        # Verify bytes against the manifest digest selected by Terraform state.
        # Reuse the serving image's Python; this container has no AWS token.
        init_container {
          name    = "verify-model"
          image   = "vllm/vllm-openai:${var.vllm_version}"
          command = ["python3", "/opt/model-tools/manifest.py"]
          args = [
            "--directory", "/models/model",
            "--manifest", "/models/manifest.json",
            "--manifest-sha256", local.stored_model.manifest_sha256,
          ]
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          resources {
            requests = { cpu = "250m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
          volume_mount {
            name       = "model"
            mount_path = "/models"
            read_only  = true
          }
          volume_mount {
            name       = "model-verifier"
            mount_path = "/opt/model-tools"
            read_only  = true
          }
        }

        container {
          name  = "vllm"
          image = "vllm/vllm-openai:${var.vllm_version}"

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

          # Read only staged artifacts; never fall back to public Hub downloads.
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

          # Model downloads finish in init containers; this probe covers engine load/warm-up
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
          name = "model-verifier"
          config_map { name = kubernetes_config_map_v1.model_verifier.metadata[0].name }
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

        # Pod-lifetime caches; models are downloaded from S3 on pod replacement.
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
      condition     = local.stored_model.model_id == var.model && local.stored_model.region == var.region && local.stored_model.cluster_name == var.cluster_name && local.stored_model.account_id == data.aws_caller_identity.current.account_id
      error_message = "The active model-store release must match this deployment's model, account, region and cluster."
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
