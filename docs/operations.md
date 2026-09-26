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

The first check should list `required_reviewers`, `branch_policy` and `true`, the second only `main`.

The first apply creates the bucket its own state lives in. `versions.tofu` gives the procedure: comment out the backend block, run `tofu apply -var piri_key_via_s3_endpoint=false` against the local backend, restore the block, then `tofu init -migrate-state`. The variable is needed until the network root's endpoint exists; "The network root" below says when to drop it. Every later apply is:

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

### The main-branch ruleset

A merge to main runs code on the box as root, so main takes the same ruleset as infra-nodes' main: no deletion, no force push, linear history, changes only through a squash-merged pull request, and the `check` and `denylist` jobs of `check.yml` passing on the latest commit. Create it once, after the first pull request has run both jobs:

```sh
gh api -X POST repos/fil-forge/forge-perf/rulesets --input - <<'EOF'
{"name": "main", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "rules": [
  {"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
  {"type": "pull_request", "parameters": {"allowed_merge_methods": ["squash"],
    "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
    "require_code_owner_review": false, "require_last_push_approval": false,
    "required_review_thread_resolution": false}},
  {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true,
    "required_status_checks": [{"context": "check", "integration_id": 15368},
                               {"context": "denylist", "integration_id": 15368}]}}]}
EOF
gh api repos/fil-forge/forge-perf/rulesets -q '.[] | [.name, .enforcement]'
```

The last command should print `["main","active"]`. `integration_id` 15368 is GitHub Actions. To require an approving review, raise `required_approving_review_count` with `gh api -X PUT repos/fil-forge/forge-perf/rulesets/<id>`.

### The network root

`terraform/envs/network` holds the forge-perf subnet (`172.31.200.0/24` in `us-east-2a` of the default VPC), its route table and the S3 gateway endpoint `forge-perf-s3`. The `deploy` workflow plans it on every pull request and applies it on every push to main.

Every command in this section runs against us-east-2, whatever region the shell defaults to:

```sh
export AWS_REGION=us-east-2
```

Before the root's first apply, check that the subnet's range is free in the default VPC and that the zone offers every tier's instance type:

```sh
vpc=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
aws ec2 describe-subnets --filters Name=vpc-id,Values="$vpc" \
  --query 'Subnets[].[CidrBlock,AvailabilityZone]' --output text
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=location,Values=us-east-2a Name=instance-type,Values=m9gd.2xlarge,m9gd.8xlarge,m9gd.16xlarge \
  --query 'InstanceTypeOfferings[].InstanceType' --output text
```

No listed block may overlap `172.31.200.0/24`, and the offerings query must print all three types. If either fails, change `terraform.tfvars` in the same pull request. The root's test reads the range and zone from `terraform.tfvars`, so it needs no change.

After the apply, the route table carries the endpoint's route to S3's prefix list:

```sh
aws ec2 describe-route-tables --filters Name=tag:Name,Values=forge-perf \
  --query 'RouteTables[0].Routes[].[DestinationCidrBlock || DestinationPrefixListId, GatewayId]' --output text
```

It should list `0.0.0.0/0` to an `igw-` gateway and a `pl-` prefix list to a `vpce-` endpoint.

Then apply the bootstrap root again. Its piri policy looks the endpoint up by its `Name` tag and binds piri's key to it with `aws:SourceVpce`. Check the policy:

```sh
aws iam get-user-policy --user-name forge-perf-piri --policy-name piri-buckets \
  --query 'PolicyDocument.Statement[].Condition' --output json
```

Every statement should name `aws:SourceVpce` and the endpoint's id. That output is the proof that the key is bound to the endpoint. A request with the key from an operator's shell is denied both before and after this apply, since the shell is outside AWS, so it shows only that the key is unusable from outside AWS. A live check of the narrowing needs an instance in a default subnet of the same VPC, the dev node's case, and a piri bucket to ask for, which exists once the box root is applied.

On a new account the network root cannot come first, because the deploy workflow needs the roles the bootstrap root creates, and the bootstrap root's endpoint lookup fails until the endpoint exists. The first bootstrap apply therefore binds piri's key to the default VPC:

```sh
tofu apply -var piri_key_via_s3_endpoint=false
```

Once the network root is applied, apply the bootstrap root again without the variable.

The endpoint's id is written into piri's policy, so a new endpoint leaves piri's key denied everywhere until the bootstrap root is applied again. The endpoint carries `prevent_destroy`, and a change that would replace it (its VPC, service or type) fails the pull request's plan. To replace it deliberately, remove `prevent_destroy` in the same pull request, and apply the bootstrap root as soon as `apply-network` finishes.

### The persistent box

`terraform/envs/box/main` holds the persistent box: the instance, its security group and role, and piri's six buckets. The `deploy` workflow plans it on every pull request. On every push to main the `box-main-changed` job plans it again, and when that plan is not empty `apply-box-main` waits for a reviewer to approve it in the `box-change` environment. The plan is in `box-main-changed`'s log. A resize stops the box and a new AMI or bootstrap replaces it, and either loses a run in progress, so approve once no run is active: `systemctl show -p ActiveState --value forge-perf-run.service` on the box prints `inactive` and `/run/forge-perf/run.lock` is free (`flock -n /run/forge-perf/run.lock true` exits 0). A plan that changes only outputs touches no infrastructure and can be approved while a run is active.

A rejected, cancelled or failed `apply-box-main` leaves the change unapplied. The next push to main plans it again and asks again; to apply it sooner, re-run the latest `deploy` run on main from the Actions tab.

All `deploy` runs on main share one concurrency group, and a run whose `apply-box-main` waits for approval is still in progress. While an approval is pending, later merges deploy nothing, `apply-network` included, until it is approved or rejected. If the box stays busy, reject the approval; the next push plans the box again and asks again.

cloud-init runs the bootstrap once per instance. It clones forge-perf at main, writes `/etc/forge-perf/box.conf`, runs `update.sh --local`, which runs `provision.sh`, installs the units and enables those in `systemd/enabled.persistent`, and writes `/etc/forge-perf/bootstrap-complete` last. Its log is `/var/log/forge-perf-bootstrap.log`. After the first apply, check the box from a shell:

```sh
scripts/operator/ssm-session.sh main
sudo -i
export AWS_REGION=us-east-2
cat /etc/forge-perf/bootstrap-complete
findmnt /var/lib/docker/volumes          # the instance-store NVMe
modprobe sch_netem && grep -m1 -o sha2 /proc/cpuinfo
echo probe | aws s3 cp - s3://forge-perf-results-654654381893/published/main/probe.json
aws s3 cp s3://forge-perf-results-654654381893/published/main/probe.json -   # AccessDenied
```

A stop and start from the console leaves the same instance with a blank instance store, which `forge-perf-nvme.service` formats before Docker starts. `findmnt` shows it again after the boot.

`scripts/operator/ssm-session.sh <box>` and `scripts/operator/box-update.sh <box>` find the running instance tagged `Box=<box>`. `box-update.sh` runs `scripts/host/update.sh` over SSM Run Command and prints its output: the checkout moves to `origin/main`, `provision.sh` reruns when `host/` or the provisioning scripts differ from the commit provisioning last succeeded at (recorded in `/var/lib/forge-perf/state/provisioned-rev`), and the units follow the checkout. Its last step writes `HEAD` to `/var/lib/forge-perf/state/updated-rev`. A failed provision leaves both records behind the reset checkout; the next poll pass sees `updated-rev` lagging, starts no run, runs `update.sh` again and counts the pass in the heartbeat's `poll_failures`, so a provision that keeps failing alerts like any other poll failure. A run started by hand in that state stops at preflight with `preflight_failed`. `scripts/host/status.sh` on the box shows the count and `updated-rev`. `update.sh` refuses while `forge-perf-run.service` is starting, running or stopping, while another process holds the run lock, on a campaign box, and when the checkout has hand edits to tracked files.

The AMI is pinned as `ami_id` in `terraform/modules/shared/constants/outputs.tf`. A new image means a new kernel, so it is an instrument change and replaces the box. `scripts/operator/latest-ami.sh` prints Canonical's newest Ubuntu 24.04 arm64 image and whether it is the pinned one; a bump is a pull request changing `ami_id` and the release date in its description.

### piri's S3 key

piri reads S3 with a static key pair belonging to the IAM user `forge-perf-piri`. The key is made by hand so the secret never enters OpenTofu state, which the plan role can read from a pull request. The user's policy admits requests only through the forge-perf S3 gateway endpoint, so the key works from a box and from nowhere else, including infra-nodes' dev node in the same VPC.

The secret goes to SSM through a temporary file readable only by you, never a command-line argument, so other users on the machine cannot read it from the process list. (AWS CLI v2 on macOS reads nothing from `file:///dev/stdin`, so a pipe into `--cli-input-json` does not work.)

```sh
key=$(aws iam create-access-key --user-name forge-perf-piri --output json)
tmp=$(mktemp)   # created mode 600
printf '%s' "$key" | jq -j .AccessKey.AccessKeyId >"$tmp"
aws ssm put-parameter --name /forge-perf/piri-s3-access-key-id --type String --value "file://$tmp"
printf '%s' "$key" | jq -j .AccessKey.SecretAccessKey >"$tmp"
aws ssm put-parameter --name /forge-perf/piri-s3-secret-access-key --type SecureString --value "file://$tmp"
rm -f "$tmp"; unset key
```

AWS allows two keys per user, which lets a new key overlap the old one until both boxes have restarted piri. When replacing a key, add `--overwrite` to both `put-parameter` calls, then delete the old one with `aws iam delete-access-key --user-name forge-perf-piri --access-key-id <old id>`.

### The harness credential through a GitHub App

The box reads fil-one/storage-qualification with a GitHub App's installation token. `SQ_AUTH=app` in `config/harness.conf` selects it. Each run, `scripts/host/harness-token.sh` signs a request with the App's private key and asks for a token scoped to that one repository and `contents: read`; the token lasts an hour and goes with the wipe.

The box role reads every parameter under `/forge-perf`, so code merged to forge-perf, smelt or the harness can read the App's private key, and the key can mint tokens for everything the App's installations grant. The App therefore does one job:

- Create a dedicated App under fil-one's Settings, Developer settings, GitHub Apps. Do not reuse an existing organization App. Turn the webhook off, and allow installation only on this account.
- Under Repository permissions, set Contents to Read-only and leave every other permission at No access. GitHub adds Metadata: Read-only to every App.
- Install it on fil-one with "Only select repositories" and pick fil-one/storage-qualification alone. The installation's settings page URL ends in the installation ID.
- On the App's settings page, note the App ID and generate a private key. The browser downloads it as a `.pem` file.

Store the three values as one SecureString. As with piri's key, the value goes through a temporary file readable only by you, never a command-line argument, and the downloaded file is deleted once stored. The private key never needs to be printed or pasted anywhere:

```sh
tmp=$(mktemp)   # created mode 600
jq -njc --arg app <app id> --arg inst <installation id> --rawfile key <downloaded>.pem \
  '{app_id: $app, installation_id: $inst, private_key: $key}' >"$tmp"
aws ssm put-parameter --name /forge-perf/harness-app --type SecureString --value "file://$tmp"
rm -f "$tmp" <downloaded>.pem
```

A 2048-bit key keeps the value under the standard tier's 4 KB limit. Check the parameter's type and fields without printing the key:

```sh
aws ssm get-parameters-by-path --path /forge-perf --query 'Parameters[].[Name,Type]' --output text
aws ssm get-parameter --with-decryption --name /forge-perf/harness-app \
  --query Parameter.Value --output text | jq -c 'keys'
```

The first line lists `/forge-perf/harness-app SecureString`; the second prints `["app_id","installation_id","private_key"]`. The next run's checkout step fetches the harness with a minted token, or ends `secrets_unavailable` with "cannot mint a harness token from the GitHub App key in SSM".

The App key is rotated yearly, and when someone with access to it leaves. An App can hold several keys at once: generate a new one, store it as above with `--overwrite` added to `put-parameter`, and delete the old key on the App's settings page after the next run fetches the harness. `SQ_AUTH=deploy-key` with a read-only deploy key in `/forge-perf/harness-deploy-key` remains in the code for an organization that allows deploy keys; fil-one does not.

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

### The scratch box's instance profile

`scripts/operator/scratch-box.sh up` launches with the instance profile named in `SCRATCH_INSTANCE_PROFILE` and the `forge-perf-scratch` security group. No root creates either. The role carries `AmazonSSMManagedInstanceCore` for a Session Manager shell. That managed policy also allows `ssm:GetParameter` on every parameter in the account, which would let a scratch box read the forge-perf secrets and infra-central's dev secrets, so the role gets the same `deny-parameter-reads` policy infra-nodes gives its node role. `up` refuses a role without it. Create the profile once:

```sh
aws iam create-role --role-name forge-perf-scratch \
  --tags Key=Project,Value=forge-perf \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name forge-perf-scratch \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name forge-perf-scratch --policy-name deny-parameter-reads \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"DenyParameterReads","Effect":"Deny","Action":"ssm:GetParameter*","Resource":"*"}]}'
aws iam create-instance-profile --instance-profile-name forge-perf-scratch \
  --tags Key=Project,Value=forge-perf
aws iam add-role-to-instance-profile --instance-profile-name forge-perf-scratch \
  --role-name forge-perf-scratch
export SCRATCH_INSTANCE_PROFILE=forge-perf-scratch
```

The security group admits no inbound traffic; Session Manager needs only outbound. `up` looks it up in the VPC of the subnet it launches into. The forge-perf subnet is in the default VPC, so one group there serves both cases:

```sh
vpc=$(aws ec2 describe-vpcs --region us-east-2 --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
aws ec2 create-security-group --region us-east-2 --vpc-id "$vpc" \
  --group-name forge-perf-scratch --description "forge-perf scratch box, no ingress" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=forge-perf}]'
```

The role reads no parameters and writes no buckets. A scratch box can provision, and cannot run the drill against AWS S3.

### Checking the roles

The `roles` workflow assumes the plan role on any pull request that touches the roles. On main, dispatch it to check that the results role can list and read `published/` and is denied `raw/`:

```sh
gh workflow run roles.yml --ref main
```

The read check fetches the first object under `published/`. Until a box publishes a heartbeat there, put a probe object for it; the `published/` lifecycle removes it after 90 days:

```sh
printf '{}\n' | aws s3 cp - s3://forge-perf-results-654654381893/published/probe.json
```

The apply role's guards can be checked without touching a resource, with the policy simulator. For an instance and a volume with no `Project` tag, each call should come back `explicitDeny`:

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names ec2:TerminateInstances \
  --resource-arns arn:aws:ec2:us-east-2:654654381893:instance/i-00000000000000000 \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names ec2:CreateTags \
  --resource-arns arn:aws:ec2:us-east-2:654654381893:volume/vol-00000000000000000 \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

With the tag in the call's context, both should come back `allowed`, so forge-perf's own resources stay manageable:

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names ec2:TerminateInstances \
  --resource-arns arn:aws:ec2:us-east-2:654654381893:instance/i-00000000000000000 \
  --context-entries ContextKeyName=aws:ResourceTag/Project,ContextKeyValues=forge-perf,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names ec2:CreateTags \
  --resource-arns arn:aws:ec2:us-east-2:654654381893:volume/vol-00000000000000000 \
  --context-entries ContextKeyName=aws:ResourceTag/Project,ContextKeyValues=forge-perf,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

EBS encrypts the box's root volume under the AWS-managed `aws/ebs` key and calls KMS as the apply role. The role may reach KMS only through EC2. Called directly, `kms:CreateGrant` on a key should come back `explicitDeny`; with `kms:ViaService` set to EC2 it should come back `implicitDeny`, which leaves the decision to the `aws/ebs` key policy, and that policy allows EC2 on behalf of any principal in the account:

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::654654381893:role/forge-perf-ci-apply \
  --action-names kms:CreateGrant \
  --resource-arns arn:aws:kms:us-east-2:654654381893:key/00000000-0000-0000-0000-000000000000 \
  --context-entries ContextKeyName=kms:ViaService,ContextKeyValues=ec2.us-east-2.amazonaws.com,ContextKeyType=string \
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

## Holding a box

A hold stops the persistent box from starting runs and updating its checkout; a run already going finishes, and new sets keep coalescing into one pending run. It is a file on the root volume, so it survives a reboot.

```sh
scripts/operator/hold.sh main on     # returns once no run is going, up to 7 hours
scripts/operator/hold.sh main off    # the newest pending set starts at the next poll
```

On the box, `scripts/host/status.sh` prints the hold, the run in progress, the pending and last sets, poll failures and the timers. Hold the box before approving a box change, before paired runs, and before anything done by hand in a shell on it.

## A campaign

A campaign runs one committed set a few times on a box of its own beside the persistent one, publishes each run and powers off. The box is `campaign`: its records land in `published/campaign/`, its piri buckets are `forge-perf-piri-campaign-654654381893-piri-0-*`, and `terraform/envs/box/campaign` holds it.

1. Commit the set under `calibration/sets/`. `scripts/operator/set-from-record.sh <run_id> calibration/sets/<name>.json` writes the set a published run ran, from the results branch.
2. Merge it, then dispatch `campaign` from main:

   ```sh
   gh workflow run campaign.yml --ref main -f action=up -f instance_type=m9gd.16xlarge -f hours=6 \
     -f set=calibration/sets/<name>.json -f runs=3 -f size=2000GB -f workers=64 -f duration=4h
   ```

| Input | Takes |
|---|---|
| `instance_type` | `m9gd.2xlarge`, `m9gd.8xlarge` or `m9gd.16xlarge`; in mode `campaign` the type needs `config/settings/<type>.env` |
| `hours` | 1 to 24. The box's `ExpiresAt` tag is the dispatch time plus this |
| `mode` | `campaign` runs the set; `calibration` boots the box and waits for the ceiling measurements |
| `set` | a committed set under `calibration/sets/`, with a digest for every image in `config/images.tracked` |
| `runs` | 1 to 20 |
| `size`, `duration` | `--stop-ingest-at` and `--duration` of each run, such as `2000GB` and `4h`; `duration` is at most `4h`, so a run fits in `forge-perf-run.service`'s 6-hour limit |
| `workers` | empty for the settings file's `WORKERS` (refused while that is empty), one number, or a comma list to sweep |

The workflow refuses bad inputs before it assumes a role, and refuses `up` while the campaign root's state holds a box. The box's first act at boot is a persistent `forge-perf-expire.timer` that powers it off at `ExpiresAt`, across reboots, so a bootstrap or recovery that fails still stops it. It then clones forge-perf at the dispatched commit and never updates. `/etc/forge-perf/campaign.json` holds the inputs, the commit and `expires_at`. `forge-perf-campaign.service` runs `scripts/host/campaign.sh`, which runs each run through `forge-perf-run.service`, flushes the outbox and powers off. If it stops on an error it also flushes the outbox and powers off. A reboot resumes the campaign after the last run that ended.

One `workers` value runs `runs` times as series `campaign`. A list is a sweep: `runs` rounds over the list, reversed every other round, so `16,32,64` with two runs goes 16, 32, 64, 64, 32, 16 (docs/DESIGN.md §9). A sweep publishes as series `calibration`, since its values are not frozen; the smallest value within 5% of the best mean p5 and median wins, and freezing it in the type's settings file is a pull request.

The box powers off when its runs are done and stops billing for compute. `campaign-reaper.yml` runs hourly. It terminates any forge-perf instance other than `main` that has no `ExpiresAt` tag, is stopped and past `ExpiresAt`, has been stopped for an hour, or is still up an hour after `ExpiresAt`, which leaves a box shutting down at `ExpiresAt` the time to record and upload its last run. For the campaign box it then destroys the campaign root, buckets included. Each finding is a line in `#filone-alerts`, and so is a failed reaper run. Once a day, and on a manual run, it also posts when the persistent box's instance type differs from `terraform/envs/box/main/terraform.tfvars`. A forgotten 12-hour tier 3 campaign costs at most 13 hours of `m9gd.16xlarge`, about $52.

To stop one sooner, dispatch `action=down`, which destroys the box and its buckets. GitHub keeps one pending run per workflow and cancels it for a newer dispatch, so check in the Actions tab that the `down` run completed, then check that nothing is left:

```sh
aws ec2 describe-instances --region us-east-2 \
  --filters Name=tag:Box,Values=campaign Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'forge-perf-piri-campaign-')].Name" --output text
```

Both should print nothing.

For the ceiling measurements, dispatch with `mode=calibration` and the type to measure, then `scripts/operator/ssm-session.sh campaign` reaches it.

## Tier 1 to tier 2

When a valid run's p5 reaches gate 1:

1. `hold.sh main on`. `set-from-record.sh <run_id> calibration/sets/tier2-bridge.json` writes the set of the run that lit the gate; commit it. On the box, run it three times at each size, with one pairing ID for the whole bridge:

   ```sh
   scripts/host/campaign.sh --set calibration/sets/tier2-bridge.json --runs 3 --pairing pair-<yyyymmdd>-t1t2
   scripts/host/campaign.sh --set calibration/sets/tier2-bridge.json --runs 3 --size 350GB --duration 4h \
     --pairing pair-<yyyymmdd>-t1t2
   ```

   Run them as root under `systemd-run --unit forge-perf-pairing --collect /bin/bash /opt/forge-perf/scripts/host/campaign.sh …`, so a closed session does not stop them, and follow with `journalctl -fu forge-perf-pairing`. On a persistent box `campaign.sh` refuses without the hold. Each run goes through `forge-perf-run.service` as the poller's would; the poller leaves the campaign's pending run alone and never retries it.
2. Merge a pull request that sets `instance_type = "m9gd.8xlarge"` in `terraform/envs/box/main/terraform.tfvars` and adds `config/settings/m9gd.8xlarge.env` with `WORKERS` empty. Approve `apply-box-main` once the box is idle ("The persistent box" above). The provider stops, modifies and starts the same instance, and the instance store comes back blank.
3. Check the new drive (`findmnt /var/lib/docker/volumes`), then sweep workers at 1×, 2× and 4× the tier 1 value with `campaign.sh --set … --runs 1 --workers <a>,<b>,<c>`, freeze the winner in a pull request, repeat the paired runs of step 1 with the same pairing ID, and `hold.sh main off`. The page marks the box change and the offset between paired medians; past values never change.

## Rotating secrets

| Secret | Where | Rotation |
|---|---|---|
| piri's S3 key | SSM `/forge-perf/piri-s3-access-key-id`, `/forge-perf/piri-s3-secret-access-key` | every 90 days |
| harness deploy key | SSM `/forge-perf/harness-deploy-key`; the public half on fil-one/storage-qualification | yearly, and when someone with access leaves |
| denylist pattern | SSM `/forge-perf/denylist`; repository secret `PUBLIC_DENYLIST_REGEX` | when the pattern changes |
| `SLACK_BOT_TOKEN` | repository secret | when the Slack app's token changes |

**piri's key.** IAM allows two keys per user, so the new key overlaps the old. Create it and store both parameters with `Overwrite: true` as in "piri's S3 key" above. Each run reads the parameters at preflight, so the next run on each box uses the new key. Confirm with `aws iam get-access-key-last-used --access-key-id <new id>`, then `aws iam update-access-key --user-name forge-perf-piri --access-key-id <old id> --status Inactive`, and delete the old key a week later.

**Harness deploy key.** Make and store a new key as in "The harness credential" above, with `--overwrite` on `put-parameter`, and add its public half beside the old one. After the next run fetches the harness, remove the old key from the repository's deploy keys.

**Slack token.** `gh secret set SLACK_BOT_TOKEN -R fil-forge/forge-perf`, then dispatch `publish.yml` once to confirm a post goes through.

Record each rotation's date here.

| Secret | Last rotated |
|---|---|
| piri's S3 key | not yet |
| harness deploy key | not yet |

## Responding to alerts

Alerts post to `#filone-alerts` from `publish.yml` (docs/publishing.md, "Alerts") and `campaign-reaper.yml`. Each run alert names the box, run ID, class and reasons, with compare links against the box's previous run. The run's raw tarball is at `s3://forge-perf-results-654654381893/raw/<box>/<run_id>/raw.tar.zst`.

| Alert | First look | Usual cause |
|---|---|---|
| `no_data`, `stack_boot_failed` or `setup_failed` | `logs/` in the raw tarball: the service that did not come up | a new `:main` image that needs a smelt change; file it on the service or on smelt with the digest |
| `no_data`, infrastructure reasons, third in a row | the reason: GHCR, SSM, S3 or a mirror fetch | an outage; the poller has retried three times, and the nightly tries again |
| `no_data`, `drill_interrupted` | `journalctl -u forge-perf-run` on the box | a reboot, a stop, or the unit's 6-hour limit |
| `failed`, `integrity_failure` | the record's failure codes | reproduce once with `run.sh --set <that set> --series calibration` on a held box before blaming a pull request |
| `invalid`, `container_restarted` or `central_ip_changed` | the restarted service's log in the tarball | a crash under load: a bug in that service |
| `invalid`, `rtt_out_of_band` or `netem_missing` | `netem/latency.json` in the tarball | a saturated host, or the sidecar image changed |
| `heartbeat_stale` | `scripts/operator/ssm-session.sh main`, then `systemctl status forge-perf-poll.timer` | the box is down, or the poll unit fails |
| `poll_failures` | `journalctl -u forge-perf-poll` | GHCR or GitHub unreachable from the box |
| `long_run` | `scripts/host/status.sh` | a drill past its duration that the watchdog has not yet stopped |
| `no_record` | the heartbeat and the outbox (`/var/lib/forge-perf/outbox`) | uploads failing, or the box held |
| reaper: a box destroyed or terminated | the line's reason | a campaign or scratch box left running past its time |
| reaper: the persistent box's type differs | `terraform/envs/box/main/terraform.tfvars` and the last `deploy` run | a resize waiting for approval, or one made by hand |

Availability errors never alert: the page shows the run as a warning and keeps its numbers. Three in a row suggest the frozen `WORKERS` pushes a service past what it serves without errors.
