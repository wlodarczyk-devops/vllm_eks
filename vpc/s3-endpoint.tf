# One shared gateway endpoint routes both ECR layer pulls and model downloads.
# Keep access to ECR's regional layer bucket if tightening the endpoint policy.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}
