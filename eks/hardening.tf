# CNI permissions belong to aws-node, rather than every process on every node.
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name                  = "${var.cluster_name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true
  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
  tags = var.tags
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Retain bootstrap administrator access for the lab; disable only after explicit access entries are verified"
  type        = bool
  default     = true
}

variable "access_entries" {
  description = "Explicit EKS access entries, keyed by role name; use least-privilege access policies"
  type = map(object({
    principal_arn = string
    policy_associations = map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string), [])
      })
    }))
  }))
  default = {}

  validation {
    condition     = var.enable_cluster_creator_admin_permissions || length(var.access_entries) > 0
    error_message = "Configure and verify explicit access entries before disabling creator admin access."
  }
}

variable "vpc_state_backend" {
  description = "Backend for reading VPC outputs; migrate the VPC state before selecting s3"
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "s3"], var.vpc_state_backend)
    error_message = "vpc_state_backend must be local or s3."
  }
}

variable "vpc_remote_state_config" {
  description = "Non-secret S3 backend settings for the VPC state (bucket, key, region); credentials come from the AWS credential chain"
  type        = map(string)
  default     = {}
  validation {
    condition     = var.vpc_state_backend != "s3" || alltrue([for k in ["bucket", "key", "region"] : try(length(var.vpc_remote_state_config[k]) > 0, false)])
    error_message = "The S3 VPC state needs bucket, key, and region."
  }
}
