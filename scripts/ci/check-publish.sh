#!/usr/bin/env bash
# Runs the publish Action's scripts against fixtures: `ingest.py --self-test`
# (the record checks), then scripts/publish/test_*.py (ingest against a stubbed
# AWS CLI, the alert rules, the site build and the data files' schemas).
# Standard library only, so they need no install.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/scripts/publish"
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1
python3 ingest.py --self-test
python3 -m unittest discover -p 'test_*.py'
