variable "image_digest" {
  description = "Reviewed vLLM sha256 digest; null keeps the lab version tag"
  type        = string
  default     = null
  validation {
    condition     = var.image_digest == null ? true : can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be null or a complete sha256 digest."
  }
}

variable "model_revision" {
  description = "Reviewed Hugging Face commit for both weights and tokenizer; null follows the lab model's default branch"
  type        = string
  default     = null
  validation {
    condition     = var.model_revision == null ? true : can(regex("^[0-9a-f]{40}$", var.model_revision))
    error_message = "model_revision must be null or a full 40-character commit."
  }
}

variable "production_mode" {
  description = "Require immutable model/container artifacts and the authenticated gateway; this is not a production certification"
  type        = bool
  default     = false
  validation {
    condition     = !var.production_mode || (var.image_digest != null && var.model_revision != null && var.gateway.enabled && var.replicas >= 2 && var.gateway.replicas >= 2 && can(regex("@sha256:[0-9a-f]{64}$", var.gateway.image)))
    error_message = "Production requires image_digest, model_revision, at least two model and gateway replicas, gateway.enabled, and a digest-pinned gateway image."
  }
}

variable "ephemeral_storage_request" {
  description = "Node disk reserved for model cache, temporary files and container logs"
  type        = string
  default     = "40Gi"
}

variable "ephemeral_storage_limit" {
  description = "Pod ephemeral storage limit, with headroom above the 30Gi home and 5Gi tmp volumes"
  type        = string
  default     = "45Gi"
}

resource "kubernetes_pod_disruption_budget_v1" "vllm" {
  # Do not block deliberate scale-to-zero or a one-replica learning deployment.
  count = var.replicas >= 2 ? 1 : 0
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }
  spec {
    min_available = "1"
    selector {
      match_labels = local.labels
    }
  }
}
