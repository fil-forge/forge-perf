#!/usr/bin/env bash
# Formats and validates every OpenTofu root under terraform/envs.
#
# A root is a directory holding a versions.tofu, at any depth, so box/main and
# box/campaign are found the same way as network. Each root also needs the
# versions.tf that stops Terraform from running there: Terraform stamps its own
# version into the state it writes, and OpenTofu then refuses to read it.
#
# -backend=false because validating a root does not need its state, and reaching
# the state bucket would need credentials the CI job does not have.
# -lockfile=readonly because a provider missing from a committed lock file
# would otherwise be resolved to whatever is newest and pass here while the
# apply resolves something else.
#
# CI pins OpenTofu 1.12.5; the version line below says which one ran.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

roots=()
while IFS= read -r file; do
  roots+=("$(dirname "$file")")
done < <(find terraform/envs -name versions.tofu -not -path '*/.terraform/*' 2>/dev/null | sort)

if [ "${#roots[@]}" -eq 0 ]; then
  echo "tofu: no roots under terraform/envs" >&2
  exit 1
fi

tofu version | sed -n 1p
tofu fmt -check -diff -recursive terraform

for root in "${roots[@]}"; do
  echo "--> $root"
  if ! grep -q 'required_version = "< 0.0.0"' "$root/versions.tf" 2>/dev/null; then
    echo "tofu: $root has no versions.tf refusing Terraform" >&2
    exit 1
  fi
  tofu -chdir="$root" init -backend=false -input=false -lockfile=readonly >/dev/null
  tofu -chdir="$root" validate
done
echo "tofu: ${#roots[@]} root(s) valid"
