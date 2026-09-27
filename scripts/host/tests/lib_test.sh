#!/usr/bin/env bash
# Behavior of the helpers in lib.sh that the other tests do not reach: instance
# metadata over IMDSv2, the skip mode of each host wrapper, and the refusal of
# skip mode on a box. curl is stubbed on PATH; http://no-imds.test is a host
# where no instance metadata answers.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/lib-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export LOG="$work/calls"

# IMDSv2: the PUT returns a token, the GET must carry it.
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$LOG"
case "$*" in
  *no-imds.test*) exit 7 ;;
  *"-X PUT"*"/latest/api/token"*) printf tok123 ;;
  *"X-aws-ec2-metadata-token: tok123"*"/latest/meta-data/instance-type") printf m9gd.2xlarge ;;
  *) exit 22 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho 0\n' >"$work/bin/id"
chmod +x "$work/bin/"*

failures=0
out="$work/out"

# check <want-status> <description> <snippet> [VAR=value ...]: run the snippet
# in a shell that has sourced lib.sh, and keep its output in $out.
check() {
  local want="$1" what="$2" snippet="$3" got=0
  shift 3
  : >"$LOG"
  env -u INVOCATION_ID PATH="$work/bin:$PATH" FORGE_PERF_CHECKOUT="$repo" "$@" \
    bash -c 'set -euo pipefail; . "$FORGE_PERF_CHECKOUT/scripts/host/lib.sh"; '"$snippet" >"$out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $what: exit $got, want $want"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
    return 1
  fi
}

ok() { echo "ok: $1"; }
bad() {
  echo "FAIL: $1"
  sed 's/^/    /' "$out"
  failures=$((failures + 1))
}

if check 0 "imds" 'imds instance-type' FORGE_PERF_IMDS_URL=http://imds.test; then
  [ "$(cat "$out")" = m9gd.2xlarge ] && ok "imds reads metadata with an IMDSv2 token" || bad "imds"
fi
skip=(FORGE_PERF_HOST_OPS=skip FORGE_PERF_IMDS_URL=http://no-imds.test)
if check 0 "imds skipped" 'imds instance-type' "${skip[@]}"; then
  [ "$(tail -1 "$out")" = local ] && ! grep -q meta-data "$LOG" && ok "skip mode answers imds with 'local'" ||
    bad "imds skipped"
fi

if check 0 "wrappers skipped" 'host_op false; host_read false; if host_check true; then echo acted; fi' \
  "${skip[@]}"; then
  ! grep -q acted "$out" && [ "$(grep -c skipped "$out")" -eq 3 ] &&
    ok "skip mode: host_op succeeds, host_check is false, host_read prints nothing" || bad "wrappers"
fi

if check 1 "skip under systemd" 'echo loaded' "${skip[@]}" INVOCATION_ID=0123abcd; then
  grep -q "refused under systemd" "$out" && ! grep -q loaded "$out" &&
    ok "skip mode is refused under systemd" || bad "skip under systemd"
fi
if check 1 "skip on EC2" 'echo loaded' FORGE_PERF_HOST_OPS=skip FORGE_PERF_IMDS_URL=http://imds.test; then
  grep -q "refused on an EC2 instance" "$out" && ! grep -q loaded "$out" &&
    ok "skip mode is refused where instance metadata answers" || bad "skip on EC2"
fi
box_conf="$work/box.conf"
printf 'FORGE_PERF_HOST_OPS=skip\nFORGE_PERF_BOX_ID=b\nFORGE_PERF_CHECKOUT=%s\n' "$repo" >"$box_conf"
if check 1 "skip from box.conf" 'forge_perf_init; echo loaded' FORGE_PERF_BOX_CONF="$box_conf" \
  FORGE_PERF_IMDS_URL=http://imds.test; then
  grep -q "refused on an EC2 instance" "$out" && ! grep -q loaded "$out" &&
    ok "skip mode set in box.conf is refused on the box" || bad "skip from box.conf"
fi

if [ "$failures" -ne 0 ]; then
  echo "lib_test: $failures failure(s)"
  exit 1
fi
echo "lib_test: all passed"
