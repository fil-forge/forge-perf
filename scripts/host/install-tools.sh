#!/usr/bin/env bash
# Install the pinned tools that do not come from apt: Go, ucantool and AWS CLI
# v2, each at the version and checksum in host/versions.env.
#
# Run by provision.sh. Each download is checked with sha256sum before anything
# is extracted, and a /etc/forge-perf/<name>.version stamp records which pin
# installed a tool, so a re-run with unchanged pins downloads nothing.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

forge_perf_init
arch="${TARGET_PLATFORM#linux_}"

# fetch <url> <sha256> <dest>: download and verify, or die.
fetch() {
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || die "checksum mismatch for $1"
}

# pinned <name> <version>: 0 when the stamp records this pin and the binary is
# there. provision.sh counts each "  installed" line as a change.
pinned() {
  [ "$(cat "$R/etc/forge-perf/$1.version" 2>/dev/null)" = "$2 $TARGET_PLATFORM" ] &&
    [ -x "$R/usr/local/bin/$1" ] && {
    echo "  $1 already at $2"
  }
}

stamp() {
  printf '%s %s\n' "$2" "$TARGET_PLATFORM" >"$R/etc/forge-perf/$1.version"
  echo "  installed $1 $2"
}

step "tools"
if host_ops_skipped; then
  echo "host-op skipped: install go $GO_VERSION, ucantool $UCANTOOL_VERSION, aws $AWSCLI_VERSION" >&2
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Go into /usr/local/go, replaced whole so no file from an older release stays.
if ! pinned go "$GO_VERSION"; then
  fetch "https://go.dev/dl/go$GO_VERSION.linux-$arch.tar.gz" "$GO_SHA256" "$tmp/go.tgz"
  rm -rf /usr/local/go
  tar -xzf "$tmp/go.tgz" -C /usr/local
  # GOTOOLCHAIN=local for every go on the box: a newer go line in a go.mod fails
  # the build instead of downloading another toolchain.
  sed -i 's/^GOTOOLCHAIN=.*/GOTOOLCHAIN=local/' /usr/local/go/go.env
  grep -qx GOTOOLCHAIN=local /usr/local/go/go.env || die "cannot set GOTOOLCHAIN=local in go.env"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  stamp go "$GO_VERSION"
fi

# The release tag carries a leading v; the asset name does not.
if ! pinned ucantool "$UCANTOOL_VERSION"; then
  fetch "https://github.com/fil-forge/ucantool/releases/download/$UCANTOOL_VERSION/ucantool_${UCANTOOL_VERSION#v}_$TARGET_PLATFORM.tar.gz" \
    "$UCANTOOL_SHA256" "$tmp/ucantool.tgz"
  tar -xzf "$tmp/ucantool.tgz" -C "$tmp" ucantool
  install -m 0755 "$tmp/ucantool" /usr/local/bin/ucantool
  stamp ucantool "$UCANTOOL_VERSION"
fi

if ! pinned aws "$AWSCLI_VERSION"; then
  # AWS names arm64 aarch64.
  aws_arch="$arch"; [ "$arch" != arm64 ] || aws_arch=aarch64
  fetch "https://awscli.amazonaws.com/awscli-exe-linux-$aws_arch-$AWSCLI_VERSION.zip" \
    "$AWSCLI_SHA256" "$tmp/awscli.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  "$tmp/aws/install" --update >/dev/null
  stamp aws "$AWSCLI_VERSION"
fi

go version
ucantool --help >/dev/null
aws --version
