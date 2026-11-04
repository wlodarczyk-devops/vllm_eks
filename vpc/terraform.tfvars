region       = "eu-central-1"
name         = "vllm-eks"
cluster_name = "vllm-eks"

vpc_cidr = "10.0.0.0/16"
azs      = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

# /20 per AZ for nodes and pods
private_subnets = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
# /24 per AZ for load balancers and NAT gateway
public_subnets = ["10.0.48.0/24", "10.0.49.0/24", "10.0.50.0/24"]

enable_nat_gateway = true
single_nat_gateway = true

tags = {
  Project   = "vllm-eks"
  ManagedBy = "terraform"
}
