variable "region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "name" {
  description = "Name of the VPC and prefix for its resources"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster that will use this VPC (used in subnet discovery tags)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC"
  type        = string
}

variable "azs" {
  description = "Availability zones for the subnets"
  type        = list(string)
}

variable "private_subnets" {
  description = "CIDR blocks of the private subnets, one per AZ (EKS nodes and pods)"
  type        = list(string)
}

variable "public_subnets" {
  description = "CIDR blocks of the public subnets, one per AZ (load balancers and NAT gateway)"
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Create NAT gateway(s) for outbound traffic from private subnets"
  type        = bool
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ"
  type        = bool
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
}
