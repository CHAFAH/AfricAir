# An Ubuntu 24.04 host in the default VPC's public subnet, managed through SSM.
#   role = "web-server"      Project 1: nginx + systemd, set up by scripts/ops/bootstrap.sh
#   role = "container-host"  Project 3: Docker + Compose, deployed by CI (deploy/ec2/) through SSM Run Command

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "ubuntu" {
  # Canonical publishes the current Ubuntu 24.04 AMI here; no hard-coded AMI IDs.
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_security_group" "this" {
  name        = var.name
  description = "${var.name}: HTTP(S) from anywhere${length(var.ssh_cidrs) > 0 ? ", SSH from the operator" : ", no SSH (use SSM)"}"
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(var.tags, { Name = var.name })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  description       = "public web traffic"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.ssh_cidrs) # empty by default: Session Manager instead of port 22
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "SSH from the operator only"
}

# Unrestricted egress: the hosts install packages and reach ECR, SSM and Secrets Manager over public
# endpoints (the default VPC has no VPC endpoints); inbound is limited to 80/443 (+22 from one IP).
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "packages, ECR, SSM, Secrets Manager"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset([
    "AmazonSSMManagedInstanceCore",       # Session Manager and Run Command
    "AmazonEC2ContainerRegistryReadOnly", # Project 2: docker pull from ECR with the instance role
  ])
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_iam_role_policy" "extra" {
  count  = var.extra_policy_json == null ? 0 : 1
  role   = aws_iam_role.this.id
  policy = var.extra_policy_json
}

resource "aws_iam_instance_profile" "this" {
  name = var.name
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = var.role == "container-host" ? file("${path.module}/user-data-container-host.sh") : null

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers can't reach the instance role
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gib
    encrypted   = true
  }

  tags = merge(var.tags, { Name = var.name, Role = var.role })

  lifecycle {
    ignore_changes = [ami] # a new Ubuntu AMI should not replace a running server; rebuild deliberately
  }
}
