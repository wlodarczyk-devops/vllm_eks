variable "region" {
  description = "AWS region, matching the VPC and serving cluster"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name used to name the model bucket"
  type        = string
}

variable "tags" {
  description = "AWS resource tags"
  type        = map(string)
}
