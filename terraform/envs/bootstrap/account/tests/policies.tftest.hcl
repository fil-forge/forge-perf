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
      contains(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].Action]), "ec2:TerminateInstances"),
      contains(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].Action]), "ec2:StopInstances"),
      flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["KeepOffOtherProjects"].Condition.StringNotEquals["aws:ResourceTag/Project"]]) == ["forge-perf"],
    ])
    error_message = "the apply role must be denied stopping or terminating what lacks Project=forge-perf"
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
        for a in flatten([s.Action]) : a if can(regex("^(ssm|kms|iam:CreateUser|iam:CreateAccessKey|iam:\\*)", a))
      ]) > 0
    ]) == 0
    error_message = "the apply role must hold no ssm, kms or IAM user actions"
  }

  assert {
    condition     = toset(flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s }["WriteBoxRoles"].Resource])) == toset(["arn:aws:iam::654654381893:role/forge-perf-box-*", "arn:aws:iam::654654381893:instance-profile/forge-perf-box-*"])
    error_message = "the apply role may write box roles only"
  }

  assert {
    condition = length([
      for s in concat(values({ for s in jsondecode(module.github_actions_iam.policy_json.plan).Statement : s.Sid => s }), values({ for s in jsondecode(module.github_actions_iam.policy_json.apply).Statement : s.Sid => s })) : s
      if length([for r in flatten([s.Resource]) : r if strcontains(r, "forge-perf-results")]) > 0
    ]) == 0
    error_message = "the plan and apply roles must not reach the results bucket"
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
      for s in values({ for s in jsondecode(module.github_actions_iam.policy_json.results).Statement : s.Sid => s }) : alltrue([for r in flatten([s.Resource]) : !strcontains(r, "/raw")])
    ]) && flatten([{ for s in jsondecode(module.github_actions_iam.policy_json.results).Statement : s.Sid => s }["ListPublished"].Condition.StringLike["s3:prefix"]]) == ["published/*"]
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
