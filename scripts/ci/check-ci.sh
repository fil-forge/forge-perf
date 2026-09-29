#!/usr/bin/env bash
# Runs the tests of the CI scripts themselves, scripts/ci/tests/*_test.sh, and
# the unit tests of pr_run.py, scripts/ci/tests/test_*.py. A
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
echo "--> scripts/ci/tests/test_*.py"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py'
