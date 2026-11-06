# Gateway routing keeps S3 model transfers off the NAT gateway. This endpoint is
# shared by the private subnets; IAM/bucket policies enforce model-reader access.
# Retain the default endpoint policy so ECR layer downloads and other authorized
# S3 users continue to work. An endpoint policy never grants IAM permissions.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}
