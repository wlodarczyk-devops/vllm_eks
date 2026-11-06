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
  description = "Gateway endpoint used to constrain the model-reader IAM role"
  value       = aws_vpc_endpoint.s3.id
}
