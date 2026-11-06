variable "region" {
  description = "AWS region for the private image repository"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name used to name its vLLM image repository"
  type        = string
}

variable "tags" {
  description = "AWS resource tags"
  type        = map(string)
}
