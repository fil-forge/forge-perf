#!/usr/bin/env bash
# Behavior of check-tofu.sh against a scratch repository, with a stub `tofu` on
# PATH that records its arguments and fails on request.
set -euo pipefail

check="$(cd "$(dirname "$0")/.." && pwd -P)/check-tofu.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/tofu-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
cat >"$work/bin/tofu" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$TOFU_LOG"
case " $* " in
  *" fmt "*) [ -z "${TOFU_FAIL_FMT:-}" ] ;;
  *" validate "*) [[ "$*" != *"${TOFU_FAIL_VALIDATE:-<none>}"* ]] ;;
esac
EOF
chmod +x "$work/bin/tofu"

repo="$work/repo"
git init -q "$repo"
cd "$repo"

# root <dir>: a root with both version files.
root() {
  mkdir -p "$1"
  echo 'terraform {}' >"$1/versions.tofu"
  echo 'terraform { required_version = "< 0.0.0" }' >"$1/versions.tf"
}

failures=0
log="$work/log"
out="$work/out"

# expect <want-status> <description> [VAR=value ...]
expect() {
  local want="$1" what="$2" got=0
  shift 2
  : >"$log"
  env TOFU_LOG="$log" PATH="$work/bin:$PATH" "$@" bash "$check" >"$out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $what: exit $got, want $want"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
  else
    echo "ok: $what"
  fi
}

expect 1 "no terraform directory fails"

root terraform/envs/network
root terraform/envs/box/main
mkdir -p terraform/modules/box terraform/envs/network/.terraform/modules/x
echo 'terraform {}' >terraform/envs/network/.terraform/modules/x/versions.tofu

expect 0 "every root is checked"
want="version
fmt -check -diff -recursive terraform
-chdir=terraform/envs/box/main init -backend=false -input=false -lockfile=readonly
-chdir=terraform/envs/box/main validate
-chdir=terraform/envs/network init -backend=false -input=false -lockfile=readonly
-chdir=terraform/envs/network validate"
if [ "$(cat "$log")" != "$want" ]; then
  echo "FAIL: calls differ from the expected sequence"
  diff <(echo "$want") "$log" | sed 's/^/    /' || true
  failures=$((failures + 1))
fi

expect 1 "unformatted files fail" TOFU_FAIL_FMT=1
expect 1 "an invalid root fails" TOFU_FAIL_VALIDATE=terraform/envs/network

rm terraform/envs/box/main/versions.tf
expect 1 "a root without the Terraform guard fails"
grep -q "box/main has no versions.tf" "$out" || { echo "FAIL: missing guard not named"; failures=$((failures + 1)); }

if [ "$failures" -ne 0 ]; then
  echo "tofu_test: $failures failure(s)"
  exit 1
fi
echo "tofu_test: all passed"
