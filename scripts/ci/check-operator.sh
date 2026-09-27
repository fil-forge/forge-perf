#!/usr/bin/env bash
# Runs the tests of the operator scripts, scripts/operator/tests/*_test.sh.
# They stub aws on PATH, so they need no AWS account.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C
shopt -s nullglob
for test in scripts/operator/tests/*_test.sh; do
  echo "--> $test"
  bash "$test"
done
