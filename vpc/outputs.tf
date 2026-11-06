output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "s3_endpoint_id" {
  description = "S3 gateway endpoint shared by ECR layers and model downloads"
  value       = aws_vpc_endpoint.s3.id
}

output "ecr_endpoint_ids" {
  description = "Private ECR API and Docker registry endpoints"
  value       = { for service, endpoint in aws_vpc_endpoint.ecr : service => endpoint.id }
}

output "sts_endpoint_id" {
  description = "Private regional STS endpoint for IRSA credential exchange"
  value       = aws_vpc_endpoint.sts.id
}
