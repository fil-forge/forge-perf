# What the network root creates, checked on the plan.
#
# Placeholder credentials and the two lookups overridden, so it needs no AWS
# account: `tofu test` in this directory.

provider "aws" {
  region                      = "us-east-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_vpc.default
  values = { id = "vpc-0test" }
}

override_data {
  target = data.aws_internet_gateway.default
  values = { id = "igw-0test" }
}

run "network" {
  command = plan

  assert {
    condition = alltrue([
      aws_subnet.perf.vpc_id == "vpc-0test",
      aws_subnet.perf.cidr_block == var.subnet_cidr,
      endswith(aws_subnet.perf.cidr_block, "/24"),
      aws_subnet.perf.availability_zone == var.availability_zone,
      startswith(aws_subnet.perf.availability_zone, "us-east-2"),
      aws_subnet.perf.map_public_ip_on_launch == false,
      aws_subnet.perf.tags["Name"] == "forge-perf",
    ])
    error_message = "the subnet is terraform.tfvars' /24 in its us-east-2 zone of the default VPC, named forge-perf, with no automatic public address"
  }

  assert {
    condition = alltrue([
      aws_route_table.perf.vpc_id == "vpc-0test",
      length(aws_route_table.perf.route) == 1,
      one([for r in aws_route_table.perf.route : r.gateway_id if r.cidr_block == "0.0.0.0/0"]) == "igw-0test",
    ])
    error_message = "the route table sends 0.0.0.0/0 to the default VPC's internet gateway and nothing else"
  }

  assert {
    condition = alltrue([
      aws_vpc_endpoint.s3.vpc_id == "vpc-0test",
      aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-2.s3",
      aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway",
      aws_vpc_endpoint.s3.tags["Name"] == "forge-perf-s3",
    ])
    error_message = "the endpoint is an S3 gateway endpoint in the default VPC named forge-perf-s3"
  }

  assert {
    condition = alltrue([
      aws_subnet.perf.tags["Project"] == "forge-perf",
      aws_route_table.perf.tags["Project"] == "forge-perf",
      aws_vpc_endpoint.s3.tags["Project"] == "forge-perf",
    ])
    error_message = "every resource is tagged Project=forge-perf, which the apply role requires to manage it"
  }
}

# Fixed ids for what the plan creates, so the references between the
# resources can be compared, in a run of their own so the checks above see
# the plan as written.
run "wiring" {
  command = plan

  override_resource {
    target = aws_subnet.perf
    values = { id = "subnet-0test" }
  }

  override_resource {
    target = aws_route_table.perf
    values = { id = "rtb-0test" }
  }

  assert {
    condition = alltrue([
      aws_route_table_association.perf.subnet_id == "subnet-0test",
      aws_route_table_association.perf.route_table_id == "rtb-0test",
      aws_vpc_endpoint.s3.route_table_ids == toset(["rtb-0test"]),
    ])
    error_message = "the forge-perf subnet uses the forge-perf route table, and the endpoint serves that route table only"
  }
}
