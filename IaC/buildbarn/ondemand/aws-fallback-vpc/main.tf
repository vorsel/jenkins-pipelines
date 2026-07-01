# Dedicated, billing-isolated VPC for the BuildBarn ondemand Graviton fallback
# fleet. Lives in the buildfarm repo (NOT percona-cd-platform) so the RBE
# cluster owns its own AWS footprint. Minimal by design: one public subnet +
# IGW (no NAT gateway — ephemeral egress-only workers get a public IP, which
# is far cheaper than a NAT GW for this churny, short-lived fleet).
#
# Everything is tagged iit-billing-tag=<billing_tag> so the cost lands on a
# separate line and the percona-dev-admin reaper Lambdas spare the instances.

locals {
  base_tags = merge({
    "iit-billing-tag" = var.billing_tag
    "PerconaKeep"     = "True"
    "project"         = "psmdb-buildbarn"
    "managed-by"      = "buildbarn-ondemand"
  }, var.extra_tags)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.base_tags, { Name = "psmdb-buildbarn-rbe-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "psmdb-buildbarn-rbe-igw" })
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.subnet_cidr
  availability_zone = var.availability_zone
  # Workers are egress-only and ephemeral → give them a public IP and route
  # via the IGW instead of paying for a NAT gateway.
  map_public_ip_on_launch = true
  tags                    = merge(local.base_tags, { Name = "psmdb-buildbarn-rbe-public" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.base_tags, { Name = "psmdb-buildbarn-rbe-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "worker" {
  name_prefix = "psmdb-buildbarn-rbe-worker-"
  description = "BuildBarn ondemand Graviton worker: egress only (WireGuard + Docker Hub + CAS)"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "all outbound: WireGuard udp/51820 to the central, Docker Hub https, CAS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # No ingress: the worker initiates the WireGuard tunnel outbound; nothing
  # dials in. SSH stays closed (set AWS_KEY_NAME + widen temporarily only for
  # break-glass debugging).
  tags = merge(local.base_tags, { Name = "psmdb-buildbarn-rbe-worker-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Canonical's public SSM parameter for the latest Ubuntu arm64 AMI — surfaced
# as an output so the operator can pin AWS_AMI_ID without console hunting.
data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/arm64/hvm/ebs-gp3/ami-id"
}
