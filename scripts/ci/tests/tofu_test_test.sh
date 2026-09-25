#!/usr/bin/env bash
# Behavior of check-tofu-test.sh against a scratch repository, with a stub
# `tofu` on PATH that records its arguments and fails on request.
set -euo pipefail

check="$(cd "$(dirname "$0")/.." && pwd -P)/check-tofu-test.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/tofu-test-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
cat >"$work/bin/tofu" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TOFU_LOG"
[[ "$*" != *"${TOFU_FAIL_TEST:-<none>}"*" test "* ]]
STUB
chmod +x "$work/bin/tofu"

git init -q "$work/repo"
cd "$work/repo"

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

expect 0 "no roots with tests passes"

mkdir -p terraform/envs/network terraform/envs/bootstrap/account/tests \
  terraform/envs/network/.terraform/modules/x/tests
expect 0 "only roots with tests are tested"
want="-chdir=terraform/envs/bootstrap/account init -backend=false -input=false -lockfile=readonly
-chdir=terraform/envs/bootstrap/account test -no-color"
if [ "$(cat "$log")" != "$want" ]; then
  echo "FAIL: calls differ from the expected sequence"
  diff <(echo "$want") "$log" | sed 's/^/    /' || true
  failures=$((failures + 1))
fi

expect 1 "a failing test fails the check" TOFU_FAIL_TEST=bootstrap/account

if [ "$failures" -ne 0 ]; then
  echo "tofu_test_test: $failures failure(s)"
  exit 1
fi
echo "tofu_test_test: all passed"
