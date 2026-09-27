#!/usr/bin/env bash
# Formatting, vet and tests of the Go code (cmd/s3-ceiling). The tests talk
# only to servers they start on loopback; the module download is the one
# network access.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export GOFLAGS=-mod=readonly
go version
unformatted="$(gofmt -l cmd)"
if [ -n "$unformatted" ]; then
  echo "go: gofmt would change:" >&2
  echo "$unformatted" >&2
  exit 1
fi
go vet ./...
go test -count=1 ./...
