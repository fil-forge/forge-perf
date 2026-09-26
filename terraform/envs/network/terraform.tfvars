# Checked free in the default VPC before the first apply (docs/operations.md,
# "The network root").
subnet_cidr = "172.31.200.0/24"

# Every tier's instance type must be offered here, since a tier change keeps
# the subnet. Also where infra-nodes' dev node runs.
availability_zone = "us-east-2a"
