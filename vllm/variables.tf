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

variable "vllm_version" {
  description = "Tag of the vllm/vllm-openai image"
  type        = string
}

variable "model" {
  description = "Hugging Face model ID to serve"
  type        = string
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

variable "model_cache_host_path" {
  description = "Path on the GPU node where Hugging Face model files are cached"
  type        = string
}

variable "startup_timeout_seconds" {
  description = "Time allowed for image pull, model download and load before the pod is restarted (multiple of 60)"
  type        = number
}
