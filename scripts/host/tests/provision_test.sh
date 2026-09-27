#!/usr/bin/env bash
# Behavior of provision.sh with apt, systemctl and the other host commands
# stubbed on PATH and every /etc file written under a scratch root
# (FORGE_PERF_HOST_ROOT). Checks the first-boot order around Docker, that a
# second run changes nothing, that a new box updates apt before touching the
# Docker packages, that a Docker pin bump installs and holds the new version,
# that the drift controls act before any apt call, once, and then leave the box
# alone, that every apt-get waits for the dpkg lock, that the tools
# come from their exact URLs, and that skip mode runs no host command.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd -P)"
script="$repo/scripts/host/provision.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/provision-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export LOG="$work/calls" WORK="$work"
# shellcheck source=../../../host/versions.env
. "$repo/host/versions.env"
export DOCKER_APT_KEY_FPR

# The stubs keep state in files, so a second run sees what the first changed.
# dpkg-query answers from $WORK/dpkg ("name version" lines; absent means not
# installed) and apt-get purge removes from it. systemctl reads and updates
# $WORK/enabled and $WORK/masked (unit names); `is-active` succeeds once
# $WORK/nvme-active exists. apt-mark keeps holds in $WORK/holds and, like the
# real one, exits 100 for a package that is neither installed nor known to apt;
# apt learns the Docker packages ($WORK/apt-known) from an `apt-get update` run
# once docker.list is in place. curl records each tool URL in $WORK/urls.
cat >"$work/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
awk -v p="${!#}" '$1 == p { printf "%s", $2; found = 1 } END { exit !found }' "$WORK/dpkg"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
drop() { grep -vxF "$2" "$WORK/$1" >"$WORK/$1.new" || true; mv "$WORK/$1.new" "$WORK/$1"; }
case "$1 $2" in
  "is-enabled --quiet") grep -qxF "$3" "$WORK/enabled" ;;
  "is-enabled "*) if grep -qxF "$2" "$WORK/masked"; then echo masked; else echo enabled; fi ;;
  "is-active --quiet") [ -f "$WORK/nvme-active" ] ;;
  "disable --now") drop enabled "$3" ;;
  "mask "*) echo "$2" >>"$WORK/masked" ;;
esac
STUB
cat >"$work/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >>"$LOG"
[ "$1 $2" = "-o DPkg::Lock::Timeout=300" ] || { echo "apt-get without the lock wait" >&2; exit 1; }
shift 2
case "$1" in
  update) [ ! -f "$FORGE_PERF_HOST_ROOT/etc/apt/sources.list.d/docker.list" ] || touch "$WORK/apt-known" ;;
  purge) awk -v p="${!#}" '$1 != p' "$WORK/dpkg" >"$WORK/dpkg.new" && mv "$WORK/dpkg.new" "$WORK/dpkg" ;;
  install)
    for a in "$@"; do
      case "$a" in *=*) awk -v p="${a%%=*}" '$1 != p' "$WORK/dpkg" >"$WORK/dpkg.new"
        echo "${a%%=*} ${a#*=}" >>"$WORK/dpkg.new"; mv "$WORK/dpkg.new" "$WORK/dpkg" ;; esac
    done ;;
esac
STUB
cat >"$work/bin/apt-mark" <<'STUB'
#!/usr/bin/env bash
echo "apt-mark $*" >>"$LOG"
case "$1" in hold | unhold)
  [ -f "$WORK/apt-known" ] || for p in "${@:2}"; do
    awk -v p="$p" '$1 == p { f = 1 } END { exit !f }' "$WORK/dpkg" ||
      { echo "E: Unable to locate package $p" >&2; exit 100; }
  done ;;
esac
case "$1" in
  hold) shift; printf '%s\n' "$@" >>"$WORK/holds" ;;
  showhold) cat "$WORK/holds" ;;
esac
STUB
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a; do case "$a" in https://go.dev/* | https://github.com/* | https://awscli.*) echo "$a" >>"$WORK/urls" ;; esac; done
while [ $# -gt 1 ]; do [ "$1" = -o ] && echo key >"$2"; shift; done
STUB
# Docker's key: one primary key and a subkey. EXTRA_FPR adds a second primary.
cat >"$work/bin/gpg" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "pub:-:4096:1:8D81803C0EBFCD88:::::::scESC::::::23::0:" \
  "fpr:::::::::${FPR:-$DOCKER_APT_KEY_FPR}:" \
  "sub:-:4096:1:7EA0A9C3F273FCD8:::::::s::::::23:" "fpr:::::::::1111222233334444555566667EA0A9C3F273FCD8:"
[ -z "${EXTRA_FPR:-}" ] || printf '%s\n' "pub:-:4096:1:0000000000000000:::::::scESC::::::23::0:" "fpr:::::::::$EXTRA_FPR:"
STUB
cat >"$work/bin/uname" <<'STUB'
#!/usr/bin/env bash
case "$1" in -m) echo aarch64 ;; -r) echo 6.8.0-1030-aws ;; esac
STUB
printf '#!/usr/bin/env bash\necho 0\n' >"$work/bin/id"
for c in snap modprobe go ucantool aws; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$LOG"\n' "$c" >"$work/bin/$c"
done
chmod +x "$work/bin/"*

root="$work/root"
mkdir -p "$root/etc/forge-perf" "$root/usr/local/bin"
for t in go ucantool aws; do cp "$work/bin/$t" "$root/usr/local/bin/$t"; done
for t in "go $GO_VERSION" "ucantool $UCANTOOL_VERSION" "aws $AWSCLI_VERSION"; do
  echo "${t#* } $TARGET_PLATFORM" >"$root/etc/forge-perf/${t%% *}.version"
done
printf 'FORGE_PERF_BOX_ID=test\nFORGE_PERF_CHECKOUT=%s\n' "$repo" >"$work/box.conf"

# No timers enabled, both apt services masked, nothing held: the state after
# a first run on a box.
settled() {
  : >"$work/enabled"; : >"$work/holds"
  printf '%s\n' apt-daily.service apt-daily-upgrade.service nvmf-autoconnect.service >"$work/masked"
}

installed() {
  for p in $ARCHIVE_PACKAGES; do echo "$p 1.0"; done
  echo "docker-ce ${1:-$DOCKER_CE_VERSION}"
  echo "docker-ce-cli ${1:-$DOCKER_CE_VERSION}"
  echo "containerd.io $CONTAINERD_VERSION"
  echo "docker-compose-plugin $COMPOSE_PLUGIN_VERSION"
}

failures=0
out="$work/out"
A="apt-get -o DPkg::Lock::Timeout=300"
target="$script"

run() {
  local want="$1" what="$2" got=0
  shift 2
  : >"$LOG"
  env -u INVOCATION_ID PATH="$work/bin:$PATH" FORGE_PERF_BOX_CONF="$work/box.conf" FORGE_PERF_HOST_ROOT="$root" \
    "$@" bash "$target" >"$out" 2>&1 || got=$?
  [ "$got" -eq "$want" ] || { fail "$what: exit $got, want $want"; return 1; }
}

fail() {
  echo "FAIL: $*"
  sed 's/^/    /' "$out" "$LOG"
  failures=$((failures + 1))
}

# in_order <file> <line>...: each line appears, after the one before it.
in_order() {
  local file="$1" prev=0 n
  shift
  for l in "$@"; do
    n="$(grep -nxF -- "$l" "$file" | head -1 | cut -d: -f1)"
    [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1
    prev="$n"
  done
}

settled
installed >"$work/dpkg"
if run 0 "first run"; then
  in_order "$LOG" "systemctl stop docker.socket docker.service" "systemctl daemon-reload" \
    "systemctl enable forge-perf-nvme.service" "systemctl start forge-perf-nvme.service" \
    "systemctl start docker.service" &&
    cmp -s "$repo/host/docker/daemon.json" "$root/etc/docker/daemon.json" &&
    cmp -s "$repo/host/docker/forge-perf.conf" "$root/etc/systemd/system/docker.service.d/forge-perf.conf" &&
    ! grep -q '^apt-get .* install' "$LOG" &&
    grep -q '^=== provisioned: [1-9][0-9]* change(s) ===$' "$out" &&
    echo "ok: first run stops Docker, installs its config, then starts the NVMe and Docker in order" ||
    fail "first run: order or files wrong"
fi

touch "$work/nvme-active"
if run 0 "second run"; then
  grep -q '^=== provisioned: 0 change(s) ===$' "$out" && ! grep -qE '^systemctl (stop|start|restart)' "$LOG" &&
    echo "ok: second run changes and restarts nothing" || fail "second run: not idempotent"
fi

installed "5:29.7.2-1~ubuntu.24.04~noble" >"$work/dpkg"
if run 0 "docker pin bump"; then
  grep -qxF "$A install -y -q --no-install-recommends --allow-downgrades docker-ce=$DOCKER_CE_VERSION docker-ce-cli=$DOCKER_CE_VERSION containerd.io=$CONTAINERD_VERSION docker-compose-plugin=$COMPOSE_PLUGIN_VERSION" "$LOG" &&
    in_order "$LOG" "apt-mark unhold docker-ce docker-ce-cli containerd.io docker-compose-plugin" \
      "apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin" \
      "systemctl stop docker.socket docker.service" "systemctl start docker.service" &&
    echo "ok: a new Docker pin is installed, held, and Docker restarted" || fail "docker pin bump"
fi

installed >"$work/dpkg"
if run 1 "wrong key" FPR=0000; then
  grep -q "Docker's apt key is 0000" "$out" && echo "ok: a Docker key with another fingerprint is refused" ||
    fail "wrong key: wrong message"
fi
if run 1 "second key" EXTRA_FPR=0000; then
  grep -q "Docker's apt key is $DOCKER_APT_KEY_FPR,0000" "$out" &&
    echo "ok: a key file with a second primary key is refused" || fail "second key: wrong message"
fi

# A new box: Docker not installed, and the only apt-get update so far ran
# before docker.list existed.
installed | grep -vE '^(docker|containerd)' >"$work/dpkg"
rm -f "$root/etc/apt/sources.list.d/docker.list" "$work/apt-known" "$work/nvme-active"
if run 0 "new box"; then
  in_order "$LOG" "$A update -q" "apt-mark unhold docker-ce docker-ce-cli containerd.io docker-compose-plugin" \
    "$A install -y -q --no-install-recommends --allow-downgrades docker-ce=$DOCKER_CE_VERSION docker-ce-cli=$DOCKER_CE_VERSION containerd.io=$CONTAINERD_VERSION docker-compose-plugin=$COMPOSE_PLUGIN_VERSION" \
    "apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin" \
    "systemctl start forge-perf-nvme.service" "systemctl start docker.service" &&
    echo "ok: on a new box apt is updated before the Docker packages are unheld, installed and held" ||
    fail "new box: order wrong"
fi
touch "$work/nvme-active"

# The AMI's state: timers enabled, apt services unmasked, unattended-upgrades
# and the kernel meta-package installed and unheld.
installed >"$work/dpkg"
printf '%s\n' "linux-aws 6.8.0.1030.30" "linux-image-6.8.0-1030-aws 6.8.0-1030.32" \
  "unattended-upgrades 2.9.1" >>"$work/dpkg"
printf '%s\n' apt-daily.timer fstrim.timer motd-news.timer >"$work/enabled"
: >"$work/masked"; : >"$work/holds"
if run 0 "drift controls"; then
  grep -qxF "$A purge -y -q unattended-upgrades" "$LOG" &&
    grep -qxF "systemctl disable --now apt-daily.timer" "$LOG" &&
    grep -qxF "systemctl disable --now fstrim.timer" "$LOG" &&
    grep -qxF "systemctl mask apt-daily-upgrade.service" "$LOG" &&
    grep -qxF "systemctl mask nvmf-autoconnect.service" "$LOG" &&
    in_order "$LOG" "systemctl disable --now apt-daily.timer" "systemctl mask apt-daily.service" \
      "$(grep -m1 '^apt-get ' "$LOG")" &&
    grep -qxF "apt-mark hold linux-aws" "$LOG" &&
    grep -qxF "apt-mark hold linux-image-6.8.0-1030-aws" "$LOG" &&
    in_order "$LOG" "snap wait system seed.loaded" "snap refresh --hold" &&
    grep -q '^=== provisioned: 9 change(s) ===$' "$out" &&
    echo "ok: drift controls purge, disable, mask and hold on a fresh AMI" || fail "drift controls"
fi
if run 0 "drift controls, second run"; then
  grep -q '^=== provisioned: 0 change(s) ===$' "$out" &&
    ! grep -qE '^(apt-get .* purge|apt-mark hold|systemctl (disable|mask))' "$LOG" &&
    echo "ok: a second run leaves the drift controls alone" || fail "drift controls, second run"
fi

settled
installed >"$work/dpkg"
rm "$root/usr/local/bin/ucantool"
if run 1 "stamp without binary"; then
  grep -q "checksum mismatch for https://github.com/fil-forge/ucantool/" "$out" &&
    echo "ok: a stamp without its binary downloads the tool again" || fail "stamp without binary"
fi
cp "$work/bin/ucantool" "$root/usr/local/bin/ucantool"

# Each tool with its stamp removed: the download fails its checksum, after
# curl was asked for the exact URL of the pin.
target="$repo/scripts/host/install-tools.sh"
for t in "go https://go.dev/dl/go$GO_VERSION.linux-arm64.tar.gz" \
  "ucantool https://github.com/fil-forge/ucantool/releases/download/$UCANTOOL_VERSION/ucantool_${UCANTOOL_VERSION#v}_linux_arm64.tar.gz" \
  "aws https://awscli.amazonaws.com/awscli-exe-linux-aarch64-$AWSCLI_VERSION.zip"; do
  name="${t%% *}" url="${t#* }"
  mv "$root/etc/forge-perf/$name.version" "$work/stamp"
  : >"$work/urls"
  if run 1 "$name URL"; then
    [ "$(cat "$work/urls")" = "$url" ] && echo "ok: $name comes from $url" || fail "$name URL: got $(cat "$work/urls")"
  fi
  mv "$work/stamp" "$root/etc/forge-perf/$name.version"
done
target="$script"

rm -rf "$root/etc/docker" "$work/nvme-active"
if run 0 "skip mode" FORGE_PERF_HOST_OPS=skip FORGE_PERF_IMDS_URL=http://127.0.0.1:9; then
  [ ! -s "$LOG" ] && [ ! -e "$root/etc/docker" ] &&
    in_order "$out" "host-op skipped: systemctl stop docker.socket docker.service" \
      "host-op skipped: systemctl daemon-reload" "host-op skipped: systemctl start forge-perf-nvme.service" \
      "host-op skipped: systemctl start docker.service" &&
    echo "ok: skip mode runs no host command and logs the same order" || fail "skip mode"
fi

if [ "$failures" -ne 0 ]; then
  echo "provision_test: $failures failure(s)"
  exit 1
fi
echo "provision_test: all passed"
