variable "region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "vpc_state_path" {
  description = "Path to the VPC stack's local Terraform state file"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster (must match the cluster tag on the VPC subnets)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version of the EKS cluster"
  type        = string
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API endpoint publicly (needed for kubectl from outside the VPC)"
  type        = bool
}

variable "endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint"
  type        = list(string)

  validation {
    condition     = !var.endpoint_public_access || (length(var.endpoint_public_access_cidrs) > 0 && alltrue([for cidr in var.endpoint_public_access_cidrs : can(cidrnetmask(cidr)) && !endswith(cidr, "/0")]))
    error_message = "Public access requires valid, non-worldwide IPv4 CIDRs."
  }
}

variable "system_instance_types" {
  description = "Instance types for the system node group (cluster add-ons)"
  type        = list(string)
}

variable "system_min_size" {
  description = "Minimum number of system nodes"
  type        = number

  validation {
    condition     = var.system_min_size >= 1 && floor(var.system_min_size) == var.system_min_size
    error_message = "Keep at least one whole system node."
  }
}

variable "system_max_size" {
  description = "Maximum number of system nodes"
  type        = number

  validation {
    condition     = var.system_max_size >= var.system_min_size && floor(var.system_max_size) == var.system_max_size
    error_message = "System maximum must be a whole number at least the minimum."
  }
}

variable "system_desired_size" {
  description = "Desired number of system nodes"
  type        = number

  validation {
    condition     = var.system_desired_size >= var.system_min_size && var.system_desired_size <= var.system_max_size && floor(var.system_desired_size) == var.system_desired_size
    error_message = "System desired size must be a whole number within min/max."
  }
}

variable "gpu_instance_types" {
  description = "Instance types for the GPU node group"
  type        = list(string)
}

variable "gpu_min_size" {
  description = "Minimum number of GPU nodes"
  type        = number

  validation {
    condition     = var.gpu_min_size >= 0 && floor(var.gpu_min_size) == var.gpu_min_size
    error_message = "GPU minimum must be a nonnegative whole number."
  }
}

variable "gpu_max_size" {
  description = "Maximum number of GPU nodes"
  type        = number

  validation {
    condition     = var.gpu_max_size >= var.gpu_min_size && floor(var.gpu_max_size) == var.gpu_max_size
    error_message = "GPU maximum must be a whole number at least the minimum."
  }
}

variable "gpu_desired_size" {
  description = "Desired number of GPU nodes"
  type        = number

  validation {
    condition     = var.gpu_desired_size >= var.gpu_min_size && var.gpu_desired_size <= var.gpu_max_size && floor(var.gpu_desired_size) == var.gpu_desired_size
    error_message = "GPU desired size must be a whole number within min/max."
  }
}

variable "gpu_disk_size" {
  description = "Root volume size in GiB for GPU nodes"
  type        = number
}

variable "nvidia_device_plugin_version" {
  description = "Version of the NVIDIA device plugin Helm chart"
  type        = string
}

variable "cluster_autoscaler_chart_version" {
  description = "Version of the cluster-autoscaler Helm chart"
  type        = string
}

variable "cluster_autoscaler_image_tag" {
  description = "Cluster Autoscaler image tag; its minor version must match kubernetes_version"
  type        = string

  validation {
    condition     = startswith(var.cluster_autoscaler_image_tag, "v${var.kubernetes_version}.")
    error_message = "Autoscaler and Kubernetes minor versions must match."
  }
}

variable "cluster_autoscaler_scale_down_unneeded_time" {
  description = "How long a node must be unneeded before Cluster Autoscaler removes it (e.g. 10m)"
  type        = string
}

variable "cluster_autoscaler_scale_down_delay_after_add" {
  description = "How long after a scale-up Cluster Autoscaler waits before considering scale-down (e.g. 10m)"
  type        = string
}

variable "cluster_autoscaler_cpu_request" {
  description = "CPU request of the Cluster Autoscaler container"
  type        = string
}

variable "cluster_autoscaler_memory_request" {
  description = "Memory request of the Cluster Autoscaler container"
  type        = string
}

variable "cluster_autoscaler_memory_limit" {
  description = "Memory limit of the Cluster Autoscaler container"
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
}
