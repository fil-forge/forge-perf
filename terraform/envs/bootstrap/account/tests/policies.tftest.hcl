# What each identity in this root may do, checked on the rendered policies.
#
# Runs as a plan with placeholder credentials and the two account lookups
# overridden, so it needs no AWS account: `tofu test` in this directory.

provider "aws" {
  region                      = "us-east-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  default_tags {
    tags = { Project = "forge-perf" }
  }
}

override_data {
  target = module.github_actions_iam.data.aws_iam_openid_connect_provider.github
  values = { arn = "arn:aws:iam::654654381893:oidc-provider/token.actions.githubusercontent.com" }
}

override_data {
  target = data.aws_vpc.default
  values = { id = "vpc-0test" }
}

variables {
  budget_alert_email = "alerts@example.com"
}

run "policies" {
  command = plan


  assert {
    condition     = toset(flatten([jsondecode(module.github_actions_iam.trust_policy_json.plan).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]])) == toset(["repo:fil-forge/forge-perf:pull_request", "repo:fil-forge@280998881/forge-perf@1388269703:pull_request"])
    error_message = "the plan role must trust pull requests and nothing else"
  }

  assert {
    condition = toset(flatten([jsondecode(module.github_actions_iam.trust_policy_json.apply).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]])) == toset([
      "repo:fil-forge/forge-perf:ref:refs/heads/main", "repo:fil-forge@280998881/forge-perf@1388269703:ref:refs/heads/main",
      "repo:fil-forge/forge-perf:environment:box-change", "repo:fil-forge@280998881/forge-perf@1388269703:environment:box-change",
    ])
    error_message = "the apply role must trust main and the box-change environment, in both subject shapes"
  }

  assert {
    condition     = toset(flatten([jsondecode(module.github_actions_iam.trust_policy_json.results).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]])) == toset(["repo:fil-forge/forge-perf:ref:refs/heads/main", "repo:fil-forge@280998881/forge-perf@1388269703:ref:refs/heads/main"])
    error_message = "the results role must trust main only"
  }

  assert {
    condition = alltrue([
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].Effect == "Deny",
      try({ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].Action, null) == null,
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].NotAction])) == toset([
        "ec2:Describe*", "ec2:CreateRouteTable", "ec2:CreateSecurityGroup", "ec2:CreateSubnet", "ec2:CreateVpcEndpoint",
        "ec2:RunInstances", "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress", "ec2:CreateTags",
        "kms:CreateGrant", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:ReEncryptFrom", "kms:ReEncryptTo",
        "iam:*", "s3:*", "sts:*",
      ]),
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].Resource]) == ["*"],
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].Condition.StringNotEquals["aws:ResourceTag/Project"]]) == ["forge-perf"],
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchIntoOwnNetworkOnly"].Effect == "Deny",
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchIntoOwnNetworkOnly"].Action])) == toset(["ec2:CreateVpcEndpoint", "ec2:RunInstances"]),
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchIntoOwnNetworkOnly"].Resource])) == toset(["arn:aws:ec2:*:*:route-table/*", "arn:aws:ec2:*:*:security-group/*", "arn:aws:ec2:*:*:subnet/*"]),
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchIntoOwnNetworkOnly"].Condition.StringNotEquals["aws:ResourceTag/Project"]]) == ["forge-perf"],
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherSecurityGroups"].Effect == "Deny",
      length(setsubtract(["ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress"], flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherSecurityGroups"].Action]))) == 0,
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherSecurityGroups"].Resource]) == ["arn:aws:ec2:*:*:security-group/*"],
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherSecurityGroups"].Condition.StringNotEquals["aws:ResourceTag/Project"]]) == ["forge-perf"],
    ])
    error_message = "on a resource lacking Project=forge-perf the apply role may only describe, create in its own network and tag at creation"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : alltrue([
        for r in flatten([s.Resource]) : startswith(r, "arn:aws:s3:::forge-perf-piri-") || startswith(r, "arn:aws:s3:::forge-perf-tfstate-654654381893")
      ]) if s.Effect == "Allow" && anytrue([for a in flatten([s.Action]) : startswith(a, "s3:")])
    ])
    error_message = "every S3 grant of the apply role stays on piri's buckets or the state bucket"
  }

  assert {
    condition = alltrue([
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KmsThroughEc2Only"].Effect == "Deny",
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KmsThroughEc2Only"].Action]) == ["kms:*"],
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KmsThroughEc2Only"].Resource]) == ["*"],
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KmsThroughEc2Only"].Condition.StringNotEquals["kms:ViaService"]]) == ["ec2.us-east-2.amazonaws.com"],
    ])
    error_message = "the apply role may reach KMS only through EC2, for the box's encrypted volume"
  }

  assert {
    condition = alltrue([
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["GatewayEndpointsOnly"].Effect == "Deny",
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["GatewayEndpointsOnly"].Action]) == ["ec2:CreateVpcEndpoint"],
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["GatewayEndpointsOnly"].Resource])) == toset(["arn:aws:ec2:*:*:security-group/*", "arn:aws:ec2:*:*:subnet/*"]),
      try({ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["GatewayEndpointsOnly"].Condition, null) == null,
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchCanonicalImagesOnly"].Effect == "Deny",
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchCanonicalImagesOnly"].Action]) == ["ec2:RunInstances"],
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchCanonicalImagesOnly"].Resource])) == toset(["arn:aws:ec2:*::image/*", "arn:aws:ec2:*::snapshot/*"]),
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["LaunchCanonicalImagesOnly"].Condition.StringNotEquals["ec2:Owner"]]) == ["099720109477"],
    ])
    error_message = "the apply role may create gateway endpoints only and launch Canonical's images only"
  }

  assert {
    condition = alltrue([
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["WriteBoxRolesWithinBoundary"].Action])) == toset(["iam:CreateRole", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription"]),
      length(setintersection(toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["ManageBoxRoles"].Action])), toset(["iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription"]))) == 0,
    ])
    error_message = "deleting, updating or re-trusting a box role requires the box permissions boundary"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.github_actions_iam.policy_json.plan).Statement : alltrue([
        for r in flatten([s.Resource]) : startswith(r, "arn:aws:s3:::forge-perf-piri-") || startswith(r, "arn:aws:s3:::forge-perf-tfstate-654654381893")
      ]) if contains(flatten([s.Action]), "s3:ListBucket")
    ])
    error_message = "the plan role lists piri's buckets and the state bucket only"
  }

  assert {
    condition = alltrue([
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["NoRetaggingIntoScope"].Effect == "Deny",
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["NoRetaggingIntoScope"].Action])) == toset(["ec2:CreateTags", "ec2:DeleteTags"]),
      try(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["NoRetaggingIntoScope"].Condition.Null["ec2:CreateAction"]]), []) == ["true"],
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["NoRetaggingIntoScope"].Condition.StringNotEquals["aws:ResourceTag/Project"]]) == ["forge-perf"],
    ])
    error_message = "the apply role must not retag an existing resource outside forge-perf"
  }

  assert {
    condition = length([
      for s in values({ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }) : s if s.Effect == "Allow" && length([
        for a in flatten([s.Action]) : a if can(regex("^(ssm:|kms:|iam:\\*|iam:[A-Za-z]*(User|AccessKey|LoginProfile|Group))", a))
      ]) > 0
    ]) == 0
    error_message = "the apply role must hold no ssm, kms or IAM user actions"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : alltrue([
        for r in flatten([s.Resource]) : contains(["arn:aws:iam::654654381893:role/forge-perf-box-*", "arn:aws:iam::654654381893:instance-profile/forge-perf-box-*"], r)
      ]) if s.Effect == "Allow" && anytrue([for a in flatten([s.Action]) : startswith(a, "iam:") && !can(regex("^iam:(Get|List)", a))])
    ])
    error_message = "the apply role may write box roles only"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement :
      try(flatten([s.Condition.StringEquals["iam:PermissionsBoundary"]]), []) == ["arn:aws:iam::654654381893:policy/forge-perf-box-boundary"]
      if s.Effect == "Allow" && length(setintersection(toset(flatten([s.Action])), toset(["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy"]))) > 0
    ])
    error_message = "every role-writing action of the apply role must require the box permissions boundary"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement :
      try(flatten([s.Condition.ArnEquals["iam:PolicyARN"]]), []) == ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
      if s.Effect == "Allow" && contains(flatten([s.Action]), "iam:AttachRolePolicy")
    ])
    error_message = "a box role may have only Session Manager's managed policy attached"
  }

  assert {
    condition = alltrue([
      { for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepTheBoundary"].Effect == "Deny",
      length(setsubtract(["iam:DeleteRolePermissionsBoundary", "iam:PutRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion"], flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepTheBoundary"].Action]))) == 0,
    ])
    error_message = "the apply role must not change or remove the box boundary"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : alltrue([
        for a in flatten([s.Action]) : can(regex("^(ec2messages|ssmmessages|ssm|kms|s3):", a)) && !strcontains(a, "*")
      ])
    ])
    error_message = "the box boundary grants Session Manager, parameters and S3 only, with no wildcards"
  }

  assert {
    condition = alltrue([
      flatten([{ for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s.Sid => s }["ReadOwnParameters"].Resource]) == ["arn:aws:ssm:us-east-2:654654381893:parameter/forge-perf/*"],
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s.Sid => s }["WriteResults"].Action])) == toset(["s3:PutObject", "s3:AbortMultipartUpload"]),
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s.Sid => s }["WriteResults"].Resource])) == toset(["arn:aws:s3:::forge-perf-results-654654381893/raw/*", "arn:aws:s3:::forge-perf-results-654654381893/published/*"]),
      toset(flatten([{ for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s.Sid => s }["EmptyPiriBuckets"].Action])) == toset(["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:ListBucket", "s3:ListBucketMultipartUploads"]),
      alltrue([for r in flatten([{ for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s.Sid => s }["EmptyPiriBuckets"].Resource]) : startswith(r, "arn:aws:s3:::forge-perf-piri-")]),
      length([for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s if anytrue([for a in flatten([s.Action]) : startswith(a, "s3:")]) && !contains(["WriteResults", "EmptyPiriBuckets"], s.Sid)]) == 0,
      flatten([{ for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s.Sid => s }["DecryptParameters"].Condition.StringEquals["kms:ViaService"]]) == ["ssm.us-east-2.amazonaws.com"],
      length([for s in jsondecode(module.github_actions_iam.box_boundary_policy_json).Statement : s if anytrue([for a in flatten([s.Action]) : startswith(a, "ssm:GetParameter")]) && s.Sid != "ReadOwnParameters"]) == 0,
    ])
    error_message = "a box reads /forge-perf parameters only and writes results without reading them"
  }

  assert {
    condition = length([
      for s in concat(values({ for s in jsondecode(module.github_actions_iam.policy_json.plan).Statement : s.Sid => s }), values({ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s })) : s
      if length([for r in flatten([s.Resource]) : r if strcontains(r, "forge-perf-results")]) > 0
    ]) == 0
    error_message = "no plan or apply statement names the results bucket"
  }

  assert {
    condition = alltrue([
      for s in values({ for s in jsondecode(module.github_actions_iam.policy_json.plan).Statement : s.Sid => s }) : alltrue([
        for r in flatten([s.Resource]) : endswith(r, ".tfstate") || endswith(r, ".tflock")
      ]) if contains(flatten([s.Action]), "s3:GetObject")
    ])
    error_message = "the plan role may read state objects only"
  }

  assert {
    condition = alltrue([
      toset(flatten([for s in jsondecode(module.github_actions_iam.policy_json.results).Statement : s.Resource])) == toset(["arn:aws:s3:::forge-perf-results-654654381893", "arn:aws:s3:::forge-perf-results-654654381893/published/*"]),
      toset(flatten([for s in jsondecode(module.github_actions_iam.policy_json.results).Statement : s.Action])) == toset(["s3:ListBucket", "s3:GetObject"]),
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.results).Statement : s.Sid => s }["ListPublished"].Condition.StringLike["s3:prefix"]]) == ["published/*"],
    ])
    error_message = "the results role must reach published/ and nothing else"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(data.aws_iam_policy_document.results_bucket.json).Statement :
      s.Effect == "Deny" && endswith(flatten([s.Resource])[0], "/raw/*") &&
      flatten([s.Condition.ArnEquals["aws:PrincipalArn"]]) == ["arn:aws:iam::654654381893:role/forge-perf-ci-results"]
    ])
    error_message = "the results bucket policy must deny the results role raw/*"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(data.aws_iam_policy_document.results_bucket.json).Statement :
      s.Effect == "Deny" && toset(flatten([s.Action])) == toset(["s3:ListBucket", "s3:ListBucketVersions"]) &&
      flatten([s.Resource]) == ["arn:aws:s3:::forge-perf-results-654654381893"] &&
      flatten([s.Condition.StringNotLike["s3:prefix"]]) == ["published/*"] &&
      flatten([s.Condition.ArnEquals["aws:PrincipalArn"]]) == ["arn:aws:iam::654654381893:role/forge-perf-ci-results"]
    ])
    error_message = "the results bucket policy must deny the results role any listing outside published/"
  }

  assert {
    condition = {
      for r in aws_s3_bucket_lifecycle_configuration.results.rule : r.filter[0].prefix => r.expiration[0].days
    } == { "raw/" = 180, "published/" = 90 }
    error_message = "raw/ expires after 180 days and published/ after 90"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.piri.json).Statement :
      flatten([s.Condition.StringEquals["aws:SourceVpc"]]) == ["vpc-0test"] &&
      alltrue([for r in flatten([s.Resource]) : startswith(r, "arn:aws:s3:::forge-perf-piri-")])
    ])
    error_message = "the piri user reaches piri buckets only, from the default VPC only"
  }

  assert {
    condition     = aws_budgets_budget.forge_perf_monthly.limit_amount == "600"
    error_message = "the budget takes its amount from terraform.tfvars"
  }
}
