variable "region" {
  description = "AWS region of the EKS cluster"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster to deploy into"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for vLLM"
  type        = string
}

variable "replicas" {
  description = "Number of vLLM pods; each needs its own GPU node"
  type        = number
}

variable "progress_deadline_seconds" {
  description = "Seconds a rollout may go without a new pod becoming Ready before Kubernetes marks it failed"
  type        = number
}

variable "shutdown_timeout_seconds" {
  description = "vLLM --shutdown-timeout: seconds to let in-flight requests finish after SIGTERM"
  type        = number
}

variable "prestop_sleep_seconds" {
  description = "preStop sleep before SIGTERM, so the pod leaves the Service/InferencePool before vLLM stops"
  type        = number
}

variable "host" {
  description = "Address the vLLM API server listens on inside the container"
  type        = string

  validation {
    # Only IPv4 all-interfaces: the cluster's pod network is IPv4-only, so "::" could break probes
    condition     = var.host == "0.0.0.0"
    error_message = "host must be 0.0.0.0 (all IPv4 interfaces), otherwise the kubelet probes and the Service can't reach vLLM."
  }
}

variable "port" {
  description = "Port of the vLLM API server; also used for the container port, probes and Service"
  type        = number

  validation {
    condition     = var.port >= 1024 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number between 1024 and 65535."
  }
}

variable "dtype" {
  description = "Weight and activation dtype (half = fp16, bfloat16, auto)"
  type        = string
}

variable "max_model_len" {
  description = "Maximum context length (prompt + output tokens) per request"
  type        = number
}

variable "gpu_memory_utilization" {
  description = "Fraction of GPU memory vLLM may use for weights, activations and KV cache"
  type        = number
}

variable "cpu_request" {
  description = "CPU request of the vLLM container"
  type        = string
}

variable "memory_request" {
  description = "Memory request of the vLLM container"
  type        = string
}

variable "memory_limit" {
  description = "Memory limit of the vLLM container"
  type        = string
}

variable "shm_size" {
  description = "Size of the in-memory /dev/shm volume"
  type        = string
}

variable "home_size" {
  description = "Size limit of the writable home directory for vLLM/Triton/torch runtime caches"
  type        = string
}

variable "tmp_size" {
  description = "Size limit of the writable /tmp directory"
  type        = string
}

variable "startup_timeout_seconds" {
  description = "Time allowed after container start for engine load/warm-up; excludes init download (multiple of 10)"
  type        = number
}

variable "rollout_timeout" {
  description = "How long terraform apply waits for the Deployment to become Ready on create/update (e.g. 60m); includes image pull"
  type        = string
}
