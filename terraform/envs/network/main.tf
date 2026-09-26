# The boxes' network: a subnet of their own in the account's default VPC, its
# route table, and the S3 gateway endpoint piri's traffic goes through.
#
# The default VPC is where infra-nodes' dev node runs too. The endpoint adds a
# route to whichever route tables it is attached to, and the default subnets
# share the main one with the dev node, so the boxes get a subnet and route
# table of their own and the endpoint route stays off everyone else's traffic.
# A VPC of its own would need its own internet gateway and gain no boundary.
#
# Applied by deploy.yml on every push to main. Both box roots find the subnet
# by its Name tag, and the bootstrap root finds the endpoint by its Name tag, so
# no root reads this one's state.

# The apply role may change only what carries this tag, so every resource
# here must get it at creation. A local, so tests/network.tftest.hcl can check
# it: a test's own provider block replaces this one.
locals {
  default_tags = {
    Project = "forge-perf"
  }
}

provider "aws" {
  region              = module.constants.region
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = local.default_tags
  }
}

module "constants" {
  source = "../../modules/shared/constants"
}

variable "subnet_cidr" {
  description = "The forge-perf subnet, a /24 unused elsewhere in the default VPC."
  type        = string
}

variable "availability_zone" {
  description = "Where the subnet, and so every box, lives. It must offer every tier's instance type."
  type        = string
}

data "aws_vpc" "default" {
  default = true
}

data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# No auto-assigned public address here: a box asks for one on its own network
# interface, so an instance launched into this subnet by anything else stays
# private.
resource "aws_subnet" "perf" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = module.constants.subnet_name
  }
}

# A public subnet: egress goes straight to the internet gateway, for image
# pulls, GitHub, Session Manager and Go module downloads. No NAT gateway.
resource "aws_route_table" "perf" {
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.default.id
  }

  tags = {
    Name = module.constants.subnet_name
  }
}

resource "aws_route_table_association" "perf" {
  subnet_id      = aws_subnet.perf.id
  route_table_id = aws_route_table.perf.id
}

# Adds a route for S3's prefix list to the route table above, so the boxes'
# S3 requests stay inside AWS and carry aws:SourceVpce, which piri's key is
# bound to. The default endpoint policy allows everything; the IAM policies
# of the callers decide what they may do. A gateway endpoint costs nothing.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${module.constants.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.perf.id]

  tags = {
    Name = module.constants.s3_endpoint_name
  }
}

output "subnet_id" {
  value = aws_subnet.perf.id
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
