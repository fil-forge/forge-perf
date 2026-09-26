# Operations

Procedures an operator runs by hand against the dev account (654654381893, us-east-2). Every command assumes operator credentials for that account in the shell.

## Account setup

### The bootstrap root

`terraform/envs/bootstrap/account` holds the state bucket, the three CI roles, the results bucket, piri's IAM user and the cost budget. No workflow applies it; an operator does, once at first and again whenever it changes.

Before the first apply, create the GitHub environment `box-change`, which the apply role trusts. GitHub creates a missing environment with no protection the first time a job on any branch names it, and a job in that environment can assume the apply role. Create it with a required reviewer and main as its only deployment branch:

```sh
reviewer_id=$(gh api users/<reviewer login> -q .id)
gh api -X PUT repos/fil-forge/forge-perf/environments/box-change --input - <<EOF
{"reviewers": [{"type": "User", "id": $reviewer_id}],
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
gh api -X POST repos/fil-forge/forge-perf/environments/box-change/deployment-branch-policies \
  -f name=main -f type=branch
gh api repos/fil-forge/forge-perf/environments/box-change \
  -q '[.protection_rules[].type, .deployment_branch_policy.custom_branch_policies]'
gh api repos/fil-forge/forge-perf/environments/box-change/deployment-branch-policies \
  -q '[.branch_policies[].name]'
```

The first check should list `required_reviewers` and `true`, the second only `main`.

The first apply creates the bucket its own state lives in. `versions.tofu` gives the procedure: comment out the backend block, apply against the local backend, restore the block, then `tofu init -migrate-state`. Every later apply is:

```sh
cd terraform/envs/bootstrap/account
export TF_VAR_budget_alert_email=<who receives budget alerts>
tofu init
tofu apply
```

The alert address stays out of the committed `terraform.tfvars`, which holds only the monthly amount. AWS mails that address a confirmation link, and alerts arrive only after it is followed.

The CI roles trust the repository's OIDC subject in both shapes GitHub mints. The immutable shape is written into `main.tf`; if the repository is ever renamed or transferred, read the new one and apply again:

```sh
gh api /repos/fil-forge/forge-perf/actions/oidc/customization/sub -q .sub_claim_prefix
```

### piri's S3 key

piri reads S3 with a static key pair belonging to the IAM user `forge-perf-piri`. The key is made by hand so the secret never enters OpenTofu state, which the plan role can read from a pull request. The user's policy admits requests only from inside the default VPC, and once the network root is applied it narrows to the forge-perf S3 endpoint.

The secret travels through a pipe, never a command-line argument, so other users on the machine cannot read it from the process list:

```sh
key=$(aws iam create-access-key --user-name forge-perf-piri --output json)
printf '%s' "$key" \
  | jq '{Name: "/forge-perf/piri-s3-access-key-id", Type: "String", Value: .AccessKey.AccessKeyId}' \
  | aws ssm put-parameter --cli-input-json file:///dev/stdin
printf '%s' "$key" \
  | jq '{Name: "/forge-perf/piri-s3-secret-access-key", Type: "SecureString", Value: .AccessKey.SecretAccessKey}' \
  | aws ssm put-parameter --cli-input-json file:///dev/stdin
unset key
```

AWS allows two keys per user, which lets a new key overlap the old one until both boxes have restarted piri. When replacing a key, add `Overwrite: true` to both `jq` objects, then delete the old one with `aws iam delete-access-key --user-name forge-perf-piri --access-key-id <old id>`.

### The harness credential

The box clones fil-one/storage-qualification over SSH with a read-only deploy key. A deploy key is scoped to one repository, tied to no person and does not expire. Adding one needs admin on that repository, and the fil-one organization must allow deploy keys. The organization has them turned off today; enabling them for storage-qualification, or reading the repository through a GitHub App instead, is an open decision for the owner.

The private half is written to a RAM-backed directory where the system has one (`$XDG_RUNTIME_DIR` on most Linux desktops) and deleted as soon as it is stored:

```sh
dir=$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/sq.XXXXXX")
ssh-keygen -t ed25519 -N '' -C forge-perf-box -f "$dir/sq"
aws ssm put-parameter --name /forge-perf/harness-deploy-key \
  --type SecureString --value "file://$dir/sq"
cat "$dir/sq.pub"
rm -rf "$dir"
```

Add the printed public key under the repository's Settings, Deploy keys, with write access left off.

### The denylist pattern

The box checks each record against the same pattern CI holds in the repository secret `PUBLIC_DENYLIST_REGEX`. Store it from a file holding the pattern and nothing else:

```sh
aws ssm put-parameter --name /forge-perf/denylist \
  --type SecureString --value "file://<pattern file>"
```

When the pattern changes, update the parameter with `--overwrite` and the repository secret together.

The parameters are standard tier, and the secret ones are SecureString under the account's AWS-managed `aws/ssm` key. Check the set:

```sh
aws ssm get-parameters-by-path --path /forge-perf --query 'Parameters[].[Name,Type]' --output text
```

### The `Project` cost allocation tag

Every forge-perf resource carries `Project = forge-perf`. Cost Explorer and the `forge-perf-monthly` budget see the tag only after it is activated as a cost allocation tag, a one-time step for the account. A tag appears in the list up to a day after a resource first carries it.

```sh
aws ce list-cost-allocation-tags --tag-keys Project
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=Project,Status=Active
```

The same switch is in the Billing console under Cost allocation tags. Until it is on, the budget's filter matches no spend and never alerts.

### Checking the roles

The `roles` workflow assumes the plan role on any pull request that touches the roles. On main, dispatch it to check that the results role can list and read `published/` and is denied `raw/`:

```sh
gh workflow run roles.yml --ref main
```

The read check fetches the first object under `published/`. Until a box publishes a heartbeat there, put a probe object for it; the `published/` lifecycle removes it after 90 days:

```sh
printf '{}\n' | aws s3 cp - s3://forge-perf-results-654654381893/published/probe.json
```

The apply role's guards can be checked without touching a resource, with the policy simulator. For a resource with no `Project` tag, both actions should come back `explicitDeny`:

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names ec2:CreateTags ec2:TerminateInstances \
  --resource-arns arn:aws:ec2:us-east-2:654654381893:volume/vol-00000000000000000 \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

With the tag in the call's context, both should come back `allowed`, so forge-perf's own resources stay manageable:

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names ec2:CreateTags ec2:TerminateInstances \
  --resource-arns arn:aws:ec2:us-east-2:654654381893:volume/vol-00000000000000000 \
  --context-entries ContextKeyName=aws:ResourceTag/Project,ContextKeyValues=forge-perf,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

Every box role must carry the `forge-perf-box-boundary` permissions boundary. Creating one without it should come back `implicitDeny`:

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names iam:CreateRole \
  --resource-arns arn:aws:iam::654654381893:role/forge-perf-box-probe \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

Adding `--context-entries ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=arn:aws:iam::654654381893:policy/forge-perf-box-boundary,ContextKeyType=string` should turn it to `allowed`.
