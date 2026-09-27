#!/usr/bin/env bash
# Runs the tests of the host scripts, scripts/host/tests/*_test.sh. They stub
# docker, ip and tc on PATH, so they need neither a stack nor root.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C
shopt -s nullglob
for test in scripts/host/tests/*_test.sh; do
  echo "--> $test"
  bash "$test"
done
