# Operations

Procedures an operator runs by hand against the dev account (654654381893, us-east-2). Every command assumes operator credentials for that account in the shell.

## Account setup

### The bootstrap root

`terraform/envs/bootstrap/account` holds the state bucket, the four CI roles (plan, apply and results for this repository; request for `/forge-perf` comments in ingot, piri, sprue and hilt), the results bucket, the requests bucket, piri's IAM user and the cost budget. No workflow applies it; an operator does, once at first and again whenever it changes.

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

`terraform/envs/box/main` holds the persistent box: the instance, its security group and role, and piri's six buckets. The `deploy` workflow plans it on every pull request. On every push to main the `box-main-changed` job plans it again, and when that plan is not empty `apply-box-main` waits for a reviewer to approve it in the `box-change` environment. The plan is in `box-main-changed`'s log. A resize stops the box and a new AMI or bootstrap replaces it, and either loses a run in progress, so approve once no run is active: `systemctl show -p ActiveState --value forge-perf-run.service` on the box prints `inactive` and `/run/forge-perf/run.lock` is free (`flock -n /run/forge-perf/run.lock true` exits 0). A replacement also discards the root volume, with the outbox, the hold and the poller's state, so before approving one check that the outbox is empty: `ls -A /var/lib/forge-perf/outbox` prints nothing. If it holds files, run `scripts/host/outbox.sh flush` and look again. A plan that changes only outputs touches no infrastructure and can be approved while a run is active.

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

`scripts/operator/ssm-session.sh <box>` and `scripts/operator/box-update.sh <box>` find the running instance tagged `Box=<box>`. `box-update.sh` runs `scripts/host/update.sh` over SSM Run Command and prints its output: the checkout moves to `origin/main`, `provision.sh` reruns when `host/` or the provisioning scripts differ from the commit provisioning last succeeded at (recorded in `/var/lib/forge-perf/state/provisioned-rev`), and the units follow the checkout. Its last step writes `HEAD` to `/var/lib/forge-perf/state/updated-rev`. A failed provision leaves both records behind the reset checkout; the next poll pass sees `updated-rev` lagging, starts no run, runs `update.sh` again and counts the pass in the heartbeat's `poll_failures`, so a provision that keeps failing alerts like any other poll failure. A run started by hand in that state stops at preflight with `preflight_failed`. `scripts/host/status.sh` on the box shows the count and `updated-rev`. `update.sh` refuses while `forge-perf-run.service` or `forge-perf-experiment.service` is starting, running or stopping, while another process holds the run lock, while an experiment holds `/run/forge-perf/experiment.lock` (so both runs of a pair use one checkout), on a campaign box, and when the checkout has hand edits to tracked files.

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

### The Grafana token

Each run sends its results to the `filecoinfoundation` Grafana Cloud stack's Prometheus, and a traced run its scrubbed spans to the stack's Tempo, as infra-nodes' dev node does ([runner.md](runner.md#grafana)). Each service has its own instance ID, the basic auth user, committed in `config/grafana.conf`: Tempo `233235` at `tempo-us-central1.grafana.net:443`, Prometheus `475506` at `https://prometheus-prod-10-prod-us-central-0.grafana.net/api/prom/push`. Both take the same password, an access policy token that can write metrics and traces and nothing else. Making the token takes the Admin role in the Grafana Cloud organization.

1. Under Security, Access Policies in the Grafana Cloud portal, create a policy named `forge-perf`, limited to the `filecoinfoundation` stack, with the scopes `metrics:write` and `traces:write`. Add a token to it; the portal shows the token once. Copy it to the clipboard.
2. Put the token alone in a temporary file readable only by you. As with the other secrets, it never becomes a command-line argument:

   ```sh
   tmp=$(mktemp)   # created mode 600
   printf '%s' "$(pbpaste)" >"$tmp"
   ```

3. Check it against Prometheus without writing any data. An empty remote write request gets 400 when the token is right and 401 when it is not. `curl --config -` reads the credential from standard input, which keeps it out of the process list:

   ```sh
   printf 'user = "475506:%s"\n' "$(cat "$tmp")" | curl -s -o /dev/null -w '%{http_code}\n' --config - \
     -X POST https://prometheus-prod-10-prod-us-central-0.grafana.net/api/prom/push
   ```

4. Store it as a SecureString and remove the file:

   ```sh
   aws ssm put-parameter --name /forge-perf/grafana-token --type SecureString --value "file://$tmp"
   rm -f "$tmp"
   ```

The next run's journal shows the step: `journalctl -u forge-perf-run | grep grafana:` prints `grafana: spans <n> sent, <n> failed, <n> unsent; points <n> sent, <n> failed, <n> unsent`. Points sent with none failed means Prometheus took the token; a traced run's spans sent means Tempo did. A tier 2 nightly's spans take a few minutes to send; the step's budget grows with the trace file, up to 10 minutes ([runner.md](runner.md#size-at-10)). Without the parameter every run logs `grafana: no token in SSM; nothing sent` and goes on.

A run's spans in Tempo carry its run ID as the resource attribute `forge_perf.run_id`: in Explore, with the stack's Tempo data source, `{ resource.forge_perf.run_id = "<run_id>" }` finds them ([Reading a run's traces](#reading-a-runs-traces)).

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

## Testing a pull request with /forge-perf

A developer measures a pull request in a Forge service repository by commenting on it:

```
/forge-perf
/forge-perf pairs=2
```

The command goes on the first line of the comment. `pairs=1`, the default, runs main and then the branch; `pairs=2` runs main, branch, branch, main, which cancels slow drift across the pair at twice the box time.

The repository's `forge-perf.yml` calls [`.github/workflows/pr-run.yml`](../.github/workflows/pr-run.yml) at a forge-perf commit it pins. It reacts to the comment with a rocket and posts a comment of its own, a table with the commit, the image, the state and a link to the workflow run, which it rewrites as the request moves:

1. It builds the pull request's head commit for linux/arm64 on a native arm64 runner and pushes it only as `ghcr.io/fil-forge/<service>:pr-<n>-<sha7>`, labelled with the commit and the repository. The repository's own `main`, `latest` and `sha-*` tags are left alone.
2. It writes a request to `s3://forge-perf-requests-654654381893/requests/<id>.json` as the role `forge-perf-ci-request`.
3. It reads `status/<id>.json`, which the box writes, once a minute. The comment shows the request as waiting for pickup (the box polls every five minutes), queued with its place in line, running, and finally the result.

The result is a table with a row per run: its role (main or branch), its outcome class, its median and p5, a link to the run on the page, and for a traced run a link to its spans in Grafana, as in "Reading a run's traces" below. Under it are the branch's median and p5 deltas against main, the noise band for each and the verdict: faster, slower or within noise. The workflow run's summary carries the same text. Branch runs go through the same record as any other run and appear in the page's runs table with their pairing ID, `exp-<id>`.

**How it compares.** When the experiment starts, the box resolves main's set as its poll would: the smelt and harness SHAs and the digest of every tracked image. Main runs that set; branch runs the same set with the one service's digest replaced by the pull request's. The runs go back to back on the persistent box at the per-trigger size (500 GB on tier 2, about 10 minutes a run), traced at the settings file's ratio, and no other run starts between them. The verdict compares the median of the branch runs with the median of the main runs, and judges it on the median, which holds to about ±3.5% between runs where p5 moves about ±11%. The noise band comes from the committed tier 2 per-trigger noise band once one exists; until then it is those two figures. A difference inside the band is reported as within noise.

**Limits.**

- Only the repository's owners, members and collaborators can start one, and only for an open pull request from a branch of the same repository. A fork's pull request is refused, since its image would run on the box.
- The box runs live per-trigger and nightly runs first, starts no experiment between 02:30 and 03:30 UTC or while it is held, and starts at most four a UTC day. The rest wait in the queue.
- The box refuses a request whose service is not in `config/images.tracked` or whose image cannot be pulled; the comment shows the reason.
- The workflow waits 5 hours 30 minutes. After that the comment says it stopped waiting; the box may still run the request, and its runs then appear on the page.
- Each comment is its own request. Two comments on one pull request queue two experiments.
- To test again, comment `/forge-perf` again. Re-running all jobs of a run the box has already taken fails at the request job, since the retry would reuse the run's request id.
- The numbers are advisory. The image under test runs as built from the branch, and a service that acknowledges writes without storing them reports a high rate.

**Adding a repository.** A service repository opts in with `.github/workflows/forge-perf.yml`:

```yaml
name: forge-perf
on:
  issue_comment:
    types: [created]
permissions: {}
jobs:
  perf:
    if: >-
      github.event.issue.pull_request &&
      (github.event.comment.body == '/forge-perf' ||
       startsWith(github.event.comment.body, '/forge-perf ') ||
       startsWith(github.event.comment.body, fromJSON('"/forge-perf\t"')) ||
       startsWith(github.event.comment.body, fromJSON('"/forge-perf\r"')) ||
       startsWith(github.event.comment.body, fromJSON('"/forge-perf\n"'))) &&
      contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)
    uses: fil-forge/forge-perf/.github/workflows/pr-run.yml@<forge-perf commit, 40 hex> # main
    permissions: {contents: read, packages: write, pull-requests: write, issues: write, id-token: write}
    with: {service: <repo>, dockerfile: Dockerfile, target: prod}
```

The inputs are `service` (the repository's name, which the workflow checks), `dockerfile` and `context` (paths from the repository root, `Dockerfile` and `.` by default), `target` (empty for the last stage) and `build-args`, one `NAME=value` per line. In `build-args`, `{commit}`, `{sha7}`, `{pr}` and `{tag}` become the head commit, its first seven characters, the pull request number and the image tag, since the caller's own `github.sha` is main's on a comment. The build must produce the flavour `config/images.tracked` follows: the prod target for ingot, sprue, hilt and swarf, `Dockerfile.dev` for guppy, the plain Dockerfile for the rest. The `if` starts a run only for a comment that begins with `/forge-perf`, alone or followed by a space, tab or line break, so a comment such as `/forge-performance` starts nothing. The role `forge-perf-ci-request` trusts the main branch of ingot, piri, sprue and hilt, where comment-triggered workflows run. Another repository needs its entry in `request_repositories` in `terraform/envs/bootstrap/account/main.tf`, applied, before its comments can file a request.

The build job runs the branch's Dockerfile with `packages: write` and no AWS access. The request and wait jobs hold the role, and run only forge-perf's `scripts/ci/pr_run.py`. Every job checks it out at `job.workflow_sha`, the commit the caller pins. That role can write `requests/*` and read `status/*`, and nothing else.

**Moving the pin.** A change to `pr-run.yml` or `scripts/ci/pr_run.py` reaches a repository when its `forge-perf.yml` names a newer forge-perf commit, through a pull request in that repository. Until then a forge-perf change cannot run with that repository's `packages: write`, which covers every tag of its image. forge-perf has no release tags, so Dependabot leaves the pin alone.

## A campaign

A campaign runs one committed set a few times on a box of its own beside the persistent one, publishes each run and powers off. The box is `campaign`: its records land in `published/campaign/`, its piri buckets are `forge-perf-piri-campaign-654654381893-piri-0-*`, and `terraform/envs/box/campaign` holds it.

1. Commit the set under `calibration/sets/`. `scripts/operator/set-from-record.sh <run_id> calibration/sets/<name>.json` writes the set a published run ran, from the results branch.
2. Merge it, then dispatch `campaign` from main:

   ```sh
   gh workflow run campaign.yml --ref main -f action=up -f instance_type=m9gd.16xlarge -f hours=15 \
     -f set=calibration/sets/<name>.json -f runs=3 -f size=2000GB -f workers=64 -f duration=4h
   ```

| Input | Takes |
|---|---|
| `instance_type` | `m9gd.2xlarge`, `m9gd.8xlarge` or `m9gd.16xlarge`; in mode `campaign` the type needs `config/settings/<type>.env` |
| `hours` | 1 to 24. The box's `ExpiresAt` tag is the dispatch time plus this. In mode `campaign` the runs must fit at their longest: 30 minutes to boot, then `duration` plus 45 minutes per run, where a sweep counts each value. Three 4-hour runs need 15 hours |
| `mode` | `campaign` runs the set; `calibration` boots the box and waits for the ceiling measurements |
| `set` | a committed set under `calibration/sets/`, with a digest for every image in `config/images.tracked` |
| `runs` | 1 to 20 |
| `size`, `duration` | `--stop-ingest-at` and `--duration` of each run, such as `2000GB` and `4h`; `duration` is at most `4h`, so a run fits in `forge-perf-run.service`'s 6-hour limit |
| `workers` | empty for the settings file's `WORKERS` (refused while that is empty), one number, or a comma list to sweep |

The workflow refuses bad inputs before it assumes a role, and refuses `up` while the campaign root's state holds a box. The box's first act at boot is a persistent `forge-perf-expire.timer` that powers it off at `ExpiresAt`, across reboots, so a recovery that fails still stops it. A bootstrap that fails powers a campaign box off at once; a calibration box stays up for the operator. It then clones forge-perf at the dispatched commit and never updates. `/etc/forge-perf/campaign.json` holds the inputs, the commit and `expires_at`. `forge-perf-campaign.service` runs `scripts/host/campaign.sh`, which runs each run through `forge-perf-run.service`, flushes the outbox and powers off. If it stops on an error, including a checkout that fails, it also flushes the outbox and powers off. It starts a run only when the run's duration plus 45 minutes ends before `ExpiresAt`, and otherwise stops there. A run still going at `ExpiresAt` is interrupted, recorded and wiped during shutdown, and `forge-perf-final-flush.service` uploads the outbox after it, before the network goes down. A reboot resumes the campaign after the last run that ended.

One `workers` value runs `runs` times as series `campaign`. A list is a sweep: `runs` rounds over the list, reversed every other round, so `16,32,64` with two runs goes 16, 32, 64, 64, 32, 16 (docs/DESIGN.md §9). A sweep publishes as series `calibration`, since its values are not frozen; the smallest value within 5% of the best mean p5 and median wins, and freezing it in the type's settings file is a pull request. `scripts/operator/calibration-summary.py workers` picks the value from the sweep's run IDs ([calibration/README.md](../calibration/README.md#tier-calibration)).

The box powers off when its runs are done and stops billing for compute. `campaign-reaper.yml` runs hourly. It terminates any forge-perf instance other than `main` that has no `ExpiresAt` tag, is stopped and past `ExpiresAt`, has been stopped for an hour, or is still up an hour after `ExpiresAt`. The box powers itself off at `ExpiresAt`; the hour covers one whose own poweroff failed. Every hour it also reads the campaign root's state, and destroys the root, buckets included, when the box that state holds was just reaped or is already terminated or gone. A destroy that failed is therefore tried again the next hour, and a newer box started since the listing is left alone. Each finding is a line in `#filone-alerts`, and so is a failed reaper run. Once a day, and on a manual run, it also posts when the persistent box's instance type differs from `terraform/envs/box/main/terraform.tfvars`, and every hour it posts when `publish.yml` has not succeeded on main for 2 hours. A forgotten 15-hour tier 3 campaign costs at most 16 hours of `m9gd.16xlarge`, about $64.

To stop one sooner, dispatch `action=down`, which destroys the box and its buckets. GitHub keeps one pending run per workflow and cancels it for a newer dispatch, so check in the Actions tab that the `down` run completed, then check that nothing is left:

```sh
aws ec2 describe-instances --region us-east-2 \
  --filters Name=tag:Box,Values=campaign Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'forge-perf-piri-campaign-')].Name" --output text
```

Both should print nothing.

For the ceiling measurements, dispatch with `mode=calibration` and the type to measure, as the next section describes.

## Measuring the ceilings

Each gate on the page is one instance type's ceiling: the lower of its sustained S3 PUT rate and its instance-store NVMe write rate, each the p5 of 30-second windows (docs/DESIGN.md §9). A session measures the three types one after another on the campaign box, each in about 1 to 3 hours. [calibration/README.md](../calibration/README.md) describes the method and the files. For each type:

1. Start a calibration box. It boots, provisions and waits:

   ```sh
   gh workflow run campaign.yml --ref main -f action=up -f mode=calibration -f instance_type=m9gd.2xlarge -f hours=5
   ```

2. Once the `up` run has completed, measure it from a checkout of main:

   ```sh
   scripts/operator/calibrate-ceilings.sh m9gd.2xlarge --date <yyyy-mm-dd>
   ```

   The script waits for Session Manager to see the box, runs `scripts/host/ceiling.sh` on it over SSM Run Command, copies `s3://forge-perf-results-654654381893/raw/calibration/<date>/<type>/` to `calibration/ceilings/<date>/<type>/`, prints the summary and dispatches `down`. Check that `down` completed, as in "A campaign" above. After a failure the box stays up for a look through `ssm-session.sh campaign`, and powers off at `ExpiresAt`.

Use one date for the whole session. m9gd.2xlarge needs `hours=5`: its S3 phase runs 95 minutes, or up to 140 when its burst allowance has not visibly ended by minute 60 (the summary then carries `burst_unconfirmed`). The larger types measure S3 for 50 minutes and write their whole drive twice; `hours=4` covers them.

`--quick` runs a few minutes of each measurement and copies the evidence to `local/ceilings/`, which git ignores; it checks the path end to end before a session. `--keep` leaves the box up. `--workers N` replaces the main phase's 8 workers per vCPU.

The measurement wipes the instance store, so `ceiling.sh` refuses on any box but a campaign box in mode `calibration`. It uses piri's key against the box's own `pdp` bucket and deletes what it wrote.

When all three types are in, commit `calibration/ceilings/<date>/` with `data/gates.json` updated from the three `summary.json` files (each gate's `ceiling_bytes_per_s` is the summary's `ceiling`), in one pull request that a person reviews. Flags in a summary need a look before the gate changes: `under_driven` means twice the workers ran more than 3% faster, so that type is measured again with `--workers <that count>`; `burst_unconfirmed` means the burst allowance had not visibly ended by minute 60; `errors` means PUTs failed in the scored segment, and the S3 figure counts the bytes they read before failing.

## Tier 1 to tier 2

When a valid run's p5 reaches gate 1:

1. `hold.sh main on`. `set-from-record.sh <run_id> calibration/sets/tier2-bridge.json` writes the set of the run that lit the gate; commit and merge it, then run `scripts/operator/box-update.sh main`. The poller does not update a held box, and `update.sh` runs on one, so this brings the set to the box's checkout. On the box, run it three times at each size, with one pairing ID for the whole bridge:

   ```sh
   scripts/host/campaign.sh --set calibration/sets/tier2-bridge.json --runs 3 --pairing pair-<yyyymmdd>-t1t2
   scripts/host/campaign.sh --set calibration/sets/tier2-bridge.json --runs 3 --size 350GB --duration 4h \
     --pairing pair-<yyyymmdd>-t1t2
   ```

   Run them as root under `systemd-run --unit forge-perf-pairing --collect /bin/bash /opt/forge-perf/scripts/host/campaign.sh …`, so a closed session does not stop them, and follow with `journalctl -fu forge-perf-pairing`. On a persistent box `campaign.sh` refuses without the hold. Each run goes through `forge-perf-run.service` as the poller's would; the poller leaves the campaign's pending run alone and never retries it. A run that `run.sh` refuses before it starts writes no record; `journalctl -u forge-perf-run` says why.
2. Merge a pull request that sets `instance_type = "m9gd.8xlarge"` in `terraform/envs/box/main/terraform.tfvars`, adds `config/settings/m9gd.8xlarge.env` with `WORKERS` empty, and raises `budget_monthly_usd` in `terraform/envs/bootstrap/account/terraform.tfvars` to 1600, since tier 2 costs about $1,500 a month and the $600 forecast alert would fire every month. Apply the bootstrap root as in "The bootstrap root" above. Approve `apply-box-main` once the box is idle ("The persistent box" above). The provider stops, modifies and starts the same instance, and the instance store comes back blank. Then run `scripts/operator/box-update.sh main`, so the held box's checkout has `config/settings/m9gd.8xlarge.env`; without it `run.sh` refuses every run.
3. Check the new drive (`findmnt /var/lib/docker/volumes`), then sweep workers at 1×, 2× and 4× the tier 1 value with `campaign.sh --set … --runs 1 --workers <a>,<b>,<c>`, extend the sweep until the rate levels off, freeze a realistic value no higher than the winner in a pull request, repeat the paired runs of step 1 with the same pairing ID and the same sizes (add `--size 100GB` to the first command, since the new type's per-trigger size differs), and `hold.sh main off`. The page marks the box change and the offset between paired medians; past values never change.

## Reading a run's traces

Box runs are traced at 10% by default (`TRACE_RATIO=0.1` in each box type's settings file); `--trace RATIO` on `run.sh` or `campaign.sh` sets another ratio for a run, and `--trace 0` runs it untraced ([runner.md](runner.md#tracing)). A traced run keeps its spans in the raw tarball under `run/traces/`: the collector's `traces.jsonl`, one OTLP JSON export request per line, with `collector-metrics.txt` and `collector.log` beside it. The record carries only counts. Reading the spans takes operator credentials for the dev account, since the results role cannot read `raw/`:

```sh
scripts/operator/traces.sh <run_id>                  # to local/traces/<run_id>/
scripts/operator/traces.sh <run_id> --out DIR --jaeger
```

The script copies `s3://forge-perf-results-654654381893/raw/<box>/<run_id>/raw.tar.zst`, extracts only `traces/` to `local/traces/<run_id>/traces/`, which git ignores, and prints the summary from `scripts/operator/trace-summary.py`. A tarball without `traces/` belongs to an untraced run.

The summary's first table has a row per service and span name: count, p50, p95, p99 and total duration. ingot's `bucket.lock` and the Postgres pool waits (`pool.acquire`) come first, the rest by total time. Below it, each wait and the five spans with the most total time get a table per 10 seconds of span start, counted from the first span, so a stage that saturates after the first 30 seconds shows as durations that rise in the later rows. A line that does not parse, usually the last one of a run the box rebooted during, is counted and skipped. `trace-summary.py DIR/traces/traces.jsonl --bucket SECONDS --top N` changes the bucket width and the number of spans bucketed.

`--jaeger` then runs Jaeger v2 all-in-one, pinned in `scripts/operator/images.lock`, as container `forge-perf-jaeger` listening on 127.0.0.1 only (UI on 16686, OTLP HTTP on 4318). It POSTs each line of `traces.jsonl` to `/v1/traces` and prints the UI's address, http://127.0.0.1:16686/. The UI searches the last hour by default; set Lookback to cover the run's date. The spans live in the container's memory: `docker rm -f forge-perf-jaeger` discards them, and the next `--jaeger` replaces the container.

The same run's scrubbed spans are in Grafana too. In Explore, pick the stack's Tempo data source and run the TraceQL query

```
{ resource.forge_perf.run_id = "<run_id>" }
```

with a time range that covers the run and spans at most 7 days, since Tempo by default refuses a longer search. The page's details view for a traced run has a "Traces in Grafana" link that opens this search over the run's start to its finish, five minutes either side, and the table of recent runs on the forge-perf dashboard links each run ID to it over the dashboard's time range. Both need a Grafana login. The scrubbed spans keep their names, timing, parents and the attributes in `config/grafana-span-attributes.txt`, which is enough to follow a request through the four services and to compare `bucket.lock` and `pool.acquire` waits across runs. Adding `&& name = "bucket.lock"` inside the braces narrows the search to one span name. Anything the scrub drops, such as bucket names, object keys and SQL, is only in the raw tarball, which `traces.sh` reads.

The tarball's traces hold the drill's bucket names, object keys and SQL, and are private like the rest of the raw tarball. Keep them under `local/` or outside the repository, and never paste them into an issue or a pull request.

## The Grafana dashboard

[`docs/grafana/forge-perf.json`](grafana/forge-perf.json) is the forge-perf dashboard, in the Grafana dashboard v2 format that fil-forge/infra-central keeps its dashboards in. It shows each run's ingest p5 and median, and its objects written per second, over time with one colour per instance type, and a table of recent runs with their class and run ID, where each run ID links to a Tempo search for its spans over the dashboard's time range. Narrow the range to the week of the run before following the link, since Tempo by default refuses a search longer than 7 days. Variables filter by box and series.

infra-central installs it from `terraform/envs/grafana/dashboards/forge-perf.json`, through a pull request to that repository that copies this file, runs its `scripts/normalise-dashboard.sh`, and lets its `apply-grafana` job apply it. A change starts here and is copied across the same way. The run ID link names the Tempo data source by the UID `grafanacloud-traces`, Grafana Cloud's default, as does the page's trace link (`TEMPO_UID` in `site/model.js`); if the stack's Tempo data source has another UID (Connections, Data sources), change it in the dashboard's run ID link, where it appears twice, in `TEMPO_UID`, and in the assertion on it in `scripts/ci/tests/site_model_test.mjs`.

## Rotating secrets

| Secret | Where | Rotation |
|---|---|---|
| piri's S3 key | SSM `/forge-perf/piri-s3-access-key-id`, `/forge-perf/piri-s3-secret-access-key` | every 90 days |
| harness deploy key | SSM `/forge-perf/harness-deploy-key`; the public half on fil-one/storage-qualification | yearly, and when someone with access leaves |
| denylist pattern | SSM `/forge-perf/denylist`; repository secret `PUBLIC_DENYLIST_REGEX` | when the pattern changes |
| `SLACK_BOT_TOKEN` | repository secret | when the Slack app's token changes |
| Grafana token (Tempo and Prometheus) | SSM `/forge-perf/grafana-token` | yearly, and when someone with access leaves |

**piri's key.** IAM allows two keys per user, so the new key overlaps the old. Hold each box first (`hold.sh main on`), since a run whose preflight reads the parameters between the two writes starts piri with a mismatched pair, and release the hold once both are written. Create it and store both parameters with `Overwrite: true` as in "piri's S3 key" above. Each run reads the parameters at preflight, so the next run on each box uses the new key. Confirm with `aws iam get-access-key-last-used --access-key-id <new id>`, then `aws iam update-access-key --user-name forge-perf-piri --access-key-id <old id> --status Inactive`, and delete the old key a week later.

**Harness deploy key.** Make and store a new key as in "The harness credential" above, with `--overwrite` on `put-parameter`, and add its public half beside the old one. After the next run fetches the harness, remove the old key from the repository's deploy keys.

**Grafana token.** An access policy holds several tokens at once. Add a new token to the `forge-perf` policy, store it as in "The Grafana token" above with `--overwrite` added to `put-parameter`, and delete the old token once the next run's journal shows points sent and none failed.

**Slack token.** `gh secret set SLACK_BOT_TOKEN -R fil-forge/forge-perf`, then dispatch `publish.yml` once to confirm a post goes through.

Record each rotation's date here.

| Secret | Last rotated |
|---|---|
| piri's S3 key | not yet |
| harness deploy key | not yet |
| Grafana token | not yet |

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
| `no_record` | the heartbeat, the outbox (`/var/lib/forge-perf/outbox`) and `journalctl -u forge-perf-run` | uploads failing; the box held; the box could not read SSM `/forge-perf/denylist`, and `record.py` writes no record without it; or `WORKERS` empty in the type's settings file, so `run.sh` refuses every run |
| `forge-perf publish rejected <key>: <check>` | the check's row in docs/publishing.md, "Ingest checks" | `denylist`: SSM `/forge-perf/denylist` and the `PUBLIC_DENYLIST_REGEX` secret differ, or the box's own check was bypassed. `future_run_id`: the box's clock. `schema`: the box runs a record schema that main does not. Fix the cause, then remove the record with operator credentials: `aws s3 rm s3://forge-perf-results-654654381893/<key>` |
| reaper: `publish.yml` has not succeeded for 2 hours | the latest `publish` run's log, and `gh workflow list --all` | a revoked `SLACK_BOT_TOKEN` (which fails the run before it commits), a changed role trust, an S3 error, or the schedule disabled after 60 days without activity: `gh workflow enable publish.yml` and `gh workflow enable campaign-reaper.yml` |
| reaper: a box destroyed or terminated | the line's reason | a campaign or scratch box left running past its time. "destroying the campaign root; its box is terminated" means an earlier destroy failed; a failed run of the reaper follows if this one fails too |
| reaper: the persistent box's type differs | `terraform/envs/box/main/terraform.tfvars` and the last `deploy` run | a resize waiting for approval, or one made by hand |

Availability errors never alert: the page shows the run as a warning and keeps its numbers. Three in a row suggest the frozen `WORKERS` pushes a service past what it serves without errors.
