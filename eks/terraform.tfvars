region         = "eu-central-1"
vpc_state_path = "../vpc/terraform.tfstate"

cluster_name           = "vllm-eks"
kubernetes_version     = "1.37"
endpoint_public_access = true
# endpoint_public_access_cidrs is not committed; pass your public IP at runtime:
#   export TF_VAR_endpoint_public_access_cidrs='["<your-ip>/32"]'

# CPU nodes for CoreDNS and other add-ons
system_instance_types = ["t3.medium"]
system_min_size       = 1
system_max_size       = 2
system_desired_size   = 1

# Smallest single-GPU instances (4 vCPU each, fits the 8 vCPU G-instance quota).
# Several types improve the chance of finding capacity; tried in this order:
#   g4dn.xlarge: 1x T4,   16 GiB GPU memory
#   g5.xlarge:   1x A10G, 24 GiB GPU memory
#   g6.xlarge:   1x L4,   24 GiB GPU memory
gpu_instance_types = ["g4dn.xlarge", "g5.xlarge", "g6.xlarge"]
gpu_min_size       = 0
gpu_max_size       = 2
# Only used when the node group is created; the EKS module ignores later changes,
# so scale an existing group with `aws eks update-nodegroup-config` (see README)
gpu_desired_size = 2
gpu_disk_size    = 100

nvidia_device_plugin_version = "0.20.1"

# Cluster Autoscaler: scales node groups within their min/max sizes based on pending pods.
# Image minor version must match kubernetes_version (1.37); chart 9.60.0 ships v1.37.0.
cluster_autoscaler_chart_version              = "9.60.0"
cluster_autoscaler_image_tag                  = "v1.37.0"
cluster_autoscaler_scale_down_unneeded_time   = "10m"
cluster_autoscaler_scale_down_delay_after_add = "10m"
cluster_autoscaler_cpu_request                = "100m"
cluster_autoscaler_memory_request             = "300Mi"
cluster_autoscaler_memory_limit               = "600Mi"

tags = {
  Project   = "vllm-eks"
  ManagedBy = "terraform"
}
