resource "aws_security_group" "ecr_endpoints" {
  name_prefix = "${var.name}-ecr-endpoints-"
  description = "Private subnet HTTPS access to ECR and STS interface endpoints"
  vpc_id      = module.vpc.vpc_id
  # Responses to allowed inbound connections are stateful; no egress rule needed.
  tags = merge(var.tags, { Name = "${var.name}-ecr-endpoints" })
}

resource "aws_vpc_security_group_ingress_rule" "ecr_https" {
  for_each = toset(var.private_subnets)

  security_group_id = aws_security_group.ecr_endpoints.id
  description       = "ECR/STS HTTPS from private subnet ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# API authentication/metadata and registry pulls use separate endpoints.
resource "aws_vpc_endpoint" "ecr" {
  for_each = toset(["ecr.api", "ecr.dkr"])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.ecr_endpoints.id]
  tags                = merge(var.tags, { Name = "${var.name}-${each.value}" })
}

# IRSA exchanges a projected token with regional STS before reading model weights.
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.ecr_endpoints.id]
  tags                = merge(var.tags, { Name = "${var.name}-sts" })
}
