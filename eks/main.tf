data "terraform_remote_state" "vpc" {
  backend = "local"

  config = {
    path = var.vpc_state_path
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = var.endpoint_public_access
  endpoint_public_access_cidrs             = var.endpoint_public_access_cidrs
  enable_cluster_creator_admin_permissions = true

  # IAM Roles for Service Accounts (OIDC provider)
  enable_irsa = true

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  vpc_id     = data.terraform_remote_state.vpc.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnets

  eks_managed_node_groups = {
    # CPU nodes for cluster add-ons (CoreDNS, etc.)
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types

      min_size     = var.system_min_size
      max_size     = var.system_max_size
      desired_size = var.system_desired_size
    }

    gpu = {
      # EKS-optimized AMI with NVIDIA driver and container toolkit preinstalled
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = var.gpu_instance_types

      min_size     = var.gpu_min_size
      max_size     = var.gpu_max_size
      desired_size = var.gpu_desired_size

      # Room for the vLLM image and model weights
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.gpu_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = {
        # Matches the NVIDIA device plugin chart's default node affinity
        "nvidia.com/gpu.present" = "true"
      }

      # Only pods tolerating this taint (vLLM, NVIDIA device plugin) run on GPU nodes;
      # CoreDNS stays on system nodes, DaemonSets like kube-proxy and vpc-cni tolerate all taints
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  tags = var.tags
}

# Exposes nvidia.com/gpu as a schedulable resource on GPU nodes
resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = var.nvidia_device_plugin_version
  namespace  = "kube-system"

  depends_on = [module.eks]
}
