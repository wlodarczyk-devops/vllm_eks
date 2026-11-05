variable "region" {
  description = "AWS region of the EKS cluster"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster to deploy into"
  type        = string
}

variable "namespace" {
  description = "Namespace of the vLLM pods; the InferencePool and EPP must be in the same namespace"
  type        = string
}

variable "release_name" {
  description = "Helm release name; also the prefix of the EPP Deployment and Service"
  type        = string
}

variable "router_chart_version" {
  description = "Version of the llm-d-router-standalone Helm chart"
  type        = string
}

variable "gaie_version" {
  description = "Gateway API Inference Extension version of the vendored CRD file in crds/"
  type        = string
}

variable "model_server_labels" {
  description = "Labels selecting the vLLM pods for the InferencePool"
  type        = map(string)
}

variable "model_server_port" {
  description = "Port of the vLLM API on the model server pods"
  type        = number
}

variable "epp_cpu_request" {
  description = "CPU request of the Endpoint Picker container"
  type        = string
}

variable "epp_memory_request" {
  description = "Memory request of the Endpoint Picker container"
  type        = string
}

variable "epp_memory_limit" {
  description = "Memory limit of the Endpoint Picker container"
  type        = string
}

variable "proxy_cpu_request" {
  description = "CPU request of the Envoy sidecar"
  type        = string
}

variable "proxy_memory_request" {
  description = "Memory request of the Envoy sidecar"
  type        = string
}

variable "proxy_memory_limit" {
  description = "Memory limit of the Envoy sidecar"
  type        = string
}

variable "proxy_concurrency" {
  description = "Envoy worker threads (--concurrency); match the Envoy CPU"
  type        = number
}
