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
}

variable "gpu_instance_types" {
  description = "Instance types for the GPU node group"
  type        = list(string)
}

variable "gpu_min_size" {
  description = "Minimum number of GPU nodes"
  type        = number
}

variable "gpu_max_size" {
  description = "Maximum number of GPU nodes"
  type        = number
}

variable "gpu_desired_size" {
  description = "Desired number of GPU nodes"
  type        = number
}

variable "gpu_disk_size" {
  description = "Root volume size in GiB for GPU nodes"
  type        = number
}

variable "nvidia_device_plugin_version" {
  description = "Version of the NVIDIA device plugin Helm chart"
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
}
