#!/usr/bin/env bash
# Runs the Python tests of the host scripts, scripts/host/test_*.py: the run
# record schema against its fixtures and docs/record.md, and the schema
# checker itself. Standard library only, so they need no install.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/scripts/host"
export LC_ALL=C
# No __pycache__ in the tree, which the denylist and shellcheck would scan.
export PYTHONDONTWRITEBYTECODE=1
python3 --version
python3 -m unittest discover -p 'test_*.py'
