#!/usr/bin/env bash
# Runs the tests of scripts/operator/calibration-summary.py,
# scripts/operator/test_*.py, against fixture records. Standard library only,
# so they need no install.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/scripts/operator"
export LC_ALL=C
# No __pycache__ in the tree, which the denylist and shellcheck would scan.
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -p 'test_*.py'
