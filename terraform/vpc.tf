# VPC with two AZs:
#   public subnets   EKS nodes and the ALB (nodes get public IPs, so no NAT gateway is needed)
#   private subnets  RDS only, with no route to the internet

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index) # 10.40.0.0/20, 10.40.16.0/20
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                                  = "${local.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"              = "1" # the Load Balancer Controller puts the ALB here
    "kubernetes.io/cluster/${local.name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 100 + count.index) # 10.40.100.0/24, 10.40.101.0/24
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# The private subnets keep the VPC's main route table: local traffic only.
