locals {
  cluster_autoscaler_service_account = "cluster-autoscaler"
}

# IRSA role: the Cluster Autoscaler service account may describe the cluster's Auto Scaling groups
# and change the desired size only of groups tagged kubernetes.io/cluster/<cluster>=owned
module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name = "${var.cluster_name}-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:${local.cluster_autoscaler_service_account}"]
    }
  }

  tags = var.tags
}

# Scales node groups between min_size and max_size: adds nodes for pending pods, removes unneeded ones.
# Node groups are found by the tags EKS sets on their Auto Scaling groups
# (k8s.io/cluster-autoscaler/enabled, k8s.io/cluster-autoscaler/<cluster>).
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    cloudProvider = "aws"
    awsRegion     = var.region

    autoDiscovery = {
      clusterName = module.eks.cluster_name
    }

    image = {
      # Must match the Kubernetes minor version
      tag = var.cluster_autoscaler_image_tag
    }

    rbac = {
      serviceAccount = {
        name = local.cluster_autoscaler_service_account
        annotations = {
          "eks.amazonaws.com/role-arn" = module.cluster_autoscaler_irsa.arn
        }
      }
    }

    extraArgs = {
      # Pick the node group that wastes the least CPU/memory after scheduling the pending pods
      expander                   = "least-waste"
      scale-down-unneeded-time   = var.cluster_autoscaler_scale_down_unneeded_time
      scale-down-delay-after-add = var.cluster_autoscaler_scale_down_delay_after_add
      # Defaults kept explicit: never remove a node running pods with emptyDir (vLLM's model files)
      # or kube-system pods; such nodes are removed only once they're empty
      skip-nodes-with-local-storage = true
      skip-nodes-with-system-pods   = true
    }

    # Run on the CPU system node, never on a GPU node
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{ key = "nvidia.com/gpu.present", operator = "DoesNotExist" }]
          }]
        }
      }
    }

    resources = {
      requests = { cpu = var.cluster_autoscaler_cpu_request, memory = var.cluster_autoscaler_memory_request }
      limits   = { memory = var.cluster_autoscaler_memory_limit }
    }

    # Image runs as UID 65532 (distroless nonroot)
    securityContext = {
      runAsNonRoot   = true
      runAsUser      = 65532
      runAsGroup     = 65532
      seccompProfile = { type = "RuntimeDefault" }
    }

    containerSecurityContext = {
      allowPrivilegeEscalation = false
      readOnlyRootFilesystem   = true
      capabilities             = { drop = ["ALL"] }
    }
  })]

  depends_on = [module.eks]
}
