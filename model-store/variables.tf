variable "region" {
  description = "AWS region, matching the VPC and serving cluster"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name used to name the artifact bucket and model-reader role"
  type        = string
}

variable "vpc_state_path" {
  description = "Local VPC state containing the S3 gateway endpoint output"
  type        = string
}

variable "tags" {
  description = "AWS resource tags"
  type        = map(string)
}

variable "releases" {
  description = "Retained model releases; directory is relative to this stack. Keep old entries for rollback"
  type = map(object({
    model_id  = string
    revision  = string
    directory = string
  }))
  validation {
    condition = length(var.releases) > 0 && alltrue([
      for release in values(var.releases) : can(regex("^[0-9a-f]{40}$", release.revision)) && fileexists("${path.module}/${release.directory}/manifest.json")
    ])
    error_message = "Stage each release with prepare_model.py first; revisions must be full commit hashes."
  }
}

variable "active_release" {
  description = "Release published to the vLLM stack; old releases remain managed for rollback"
  type        = string
  validation {
    condition     = contains(keys(var.releases), var.active_release)
    error_message = "active_release must name a retained release."
  }
}
