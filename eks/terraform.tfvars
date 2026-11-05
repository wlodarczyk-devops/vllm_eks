region         = "eu-central-1"
vpc_state_path = "../vpc/terraform.tfstate"

cluster_name           = "vllm-eks"
kubernetes_version     = "1.37"
endpoint_public_access = true
# endpoint_public_access_cidrs is not committed; pass your public IP at runtime:
#   export TF_VAR_endpoint_public_access_cidrs='["<your-ip>/32"]'

# CPU nodes for CoreDNS and other add-ons; 2 nodes so both CoreDNS replicas land on different nodes
system_instance_types = ["t3.medium"]
system_min_size       = 1
system_max_size       = 2
system_desired_size   = 2

# Smallest NVIDIA GPU instance: 1x T4, 16 GiB GPU memory
gpu_instance_types = ["g4dn.xlarge"]
gpu_min_size       = 0
gpu_max_size       = 1
gpu_desired_size   = 1
gpu_disk_size      = 100

nvidia_device_plugin_version = "0.20.1"

tags = {
  Project   = "vllm-eks"
  ManagedBy = "terraform"
}
