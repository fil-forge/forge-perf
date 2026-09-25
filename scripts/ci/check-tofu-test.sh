#!/usr/bin/env bash
# Runs `tofu test` in every root under terraform/envs that has a tests/
# directory.
#
# The tests plan against placeholder credentials with the account lookups
# overridden, so they need no AWS account. They check what the rendered IAM and
# bucket policies allow, which `tofu validate` cannot see.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

roots=()
while IFS= read -r dir; do
  roots+=("$(dirname "$dir")")
done < <(find terraform/envs -type d -name tests -not -path '*/.terraform/*' 2>/dev/null | sort)

if [ "${#roots[@]}" -eq 0 ]; then
  echo "tofu test: no roots with tests"
  exit 0
fi

for root in "${roots[@]}"; do
  echo "--> $root"
  tofu -chdir="$root" init -backend=false -input=false -lockfile=readonly >/dev/null
  tofu -chdir="$root" test -no-color
done
echo "tofu test: ${#roots[@]} root(s) passed"
