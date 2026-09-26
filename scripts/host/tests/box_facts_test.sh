#!/usr/bin/env bash
# Behavior of box-facts.sh: on the box (host commands stubbed) it reports the
# instance from IMDS, the CPU model and sha2 flag, the instance-store model and
# size and the archive packages' versions; in skip mode it still prints valid
# JSON, with what the laptop cannot give as null.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/box-facts-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
printf 'FORGE_PERF_BOX_ID=main\nFORGE_PERF_CHECKOUT=%s\n' "$repo" >"$work/box.conf"

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *no-imds.test*) exit 7 ;;
  *api/token*) printf t ;;
  *meta-data/instance-type) printf m9gd.2xlarge ;;
  *meta-data/instance-id) printf i-0123456789abcdef0 ;;
  *meta-data/ami-id) printf ami-03e774c3214166a53 ;;
esac
STUB
cat >"$work/bin/awk" <<'STUB'
#!/usr/bin/env bash
# /proc is Linux-only; answer the two /proc reads, pass everything else through.
case "${!#}" in
  /proc/cpuinfo) echo "${FEATURES:-fp asimd aes pmull sha1 sha2 crc32 sha512 sve2}" ;;
  /proc/meminfo) echo 32000000 ;;
  *) exec /usr/bin/awk "$@" ;;
esac
STUB
cat >"$work/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-dno PATH,MODEL") echo "/dev/nvme0n1 Amazon Elastic Block Store"
    [ -n "${NO_STORE:-}" ] || echo "/dev/nvme1n1 Amazon EC2 NVMe Instance Storage" ;;
  "-dnbo SIZE /dev/nvme1n1") echo " 474000000000" ;;
  "-dno MODEL /dev/nvme1n1") echo "Amazon EC2 NVMe Instance Storage  " ;;
esac
STUB
cat >"$work/bin/lscpu" <<'STUB'
#!/usr/bin/env bash
printf 'Architecture:  aarch64\nModel name:    Neoverse-V3\n'
STUB
# fio and jq from the archive; chrony absent, systemd-timesyncd present.
cat >"$work/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
case "${!#}" in
  fio) printf 3.36-1ubuntu0.1 ;;
  jq) printf 1.7.1-3build1 ;;
  systemd-timesyncd) printf 255.4-1ubuntu8.10 ;;
  *) exit 1 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho 0\n' >"$work/bin/id"
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/bin/docker"
chmod +x "$work/bin/"*

failures=0
facts() { env -u INVOCATION_ID PATH="$work/bin:$PATH" FORGE_PERF_BOX_CONF="$work/box.conf" "$@" bash "$repo/scripts/host/box-facts.sh"; }
expect() {
  if jq -e "$2" "$work/out" >/dev/null; then echo "ok: $1"; else
    echo "FAIL: $1"; sed 's/^/    /' "$work/out"; failures=$((failures + 1)); fi
}

facts FORGE_PERF_IMDS_URL=http://imds.test >"$work/out"
expect "instance facts come from IMDS" \
  '.box_id == "main" and .instance == {type: "m9gd.2xlarge", id: "i-0123456789abcdef0", ami: "ami-03e774c3214166a53"}'
expect "the sha2 flag is found and the NVMe measured" \
  '.cpu.has_sha2 == true and .nvme.device == "/dev/nvme1n1" and .nvme.size_bytes == 474000000000 and .mem_total_kb == 32000000'
expect "a missing tool is null" '.versions.docker == null'
expect "the CPU and NVMe models are recorded" \
  '.cpu.model == "Neoverse-V3" and .nvme.model == "Amazon EC2 NVMe Instance Storage"'
expect "archive packages and the time daemon are recorded with their versions" \
  '.archive_packages == {fio: "3.36-1ubuntu0.1", jq: "1.7.1-3build1", "systemd-timesyncd": "255.4-1ubuntu8.10"}'

facts FORGE_PERF_IMDS_URL=http://imds.test FEATURES="fp asimd aes pmull sha1 crc32" >"$work/out"
expect "a CPU without sha2 is reported" '.cpu.has_sha2 == false'

facts FORGE_PERF_IMDS_URL=http://imds.test NO_STORE=1 >"$work/out" 2>/dev/null || : >"$work/out"
expect "no instance-store device gives null NVMe facts, not a failed record" \
  '.nvme == {device: null, model: null, size_bytes: null} and .cpu.model == "Neoverse-V3"'

facts FORGE_PERF_HOST_OPS=skip FORGE_PERF_IMDS_URL=http://no-imds.test >"$work/out" 2>/dev/null
expect "skip mode prints JSON with local and null facts" \
  '.instance.type == "local" and .cpu.has_sha2 == null and .cpu.model == null and .archive_packages == {} and .kernel_settings.dirty_ratio == null and (.forge_perf_sha | test("^[0-9a-f]{40}$"))'

if [ "$failures" -ne 0 ]; then
  echo "box_facts_test: $failures failure(s)"
  exit 1
fi
echo "box_facts_test: all passed"
