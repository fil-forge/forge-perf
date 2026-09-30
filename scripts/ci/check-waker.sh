#!/usr/bin/env bash
# Runs the tests of scripts/waker/waker.py, the Lambda that starts a sleeping
# box, against stubbed AWS clients and a stubbed GHCR and GitHub. Standard
# library only, so they need no install; boto3 is imported only in the Lambda.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/scripts/waker"
export LC_ALL=C
# No __pycache__ in the tree, which the denylist and shellcheck would scan.
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -p 'test_*.py'
