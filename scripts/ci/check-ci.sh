#!/usr/bin/env bash
# Runs the tests of the CI scripts themselves, scripts/ci/tests/*_test.sh. A
# check that silently passes everything looks the same as a clean tree, so each
# check's failure paths are exercised here against a scratch repository.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C
shopt -s nullglob
for test in scripts/ci/tests/*_test.sh; do
  echo "--> $test"
  bash "$test"
done
