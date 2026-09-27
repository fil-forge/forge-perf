#!/usr/bin/env bash
# The page's inputs and rules: data/*.json against their schemas and the gate
# rules (scripts/publish/check_data.py), then site/model.js under node's test
# runner. site/package.json declares the site's scripts ES modules, so node
# needs no install and no module detection.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export PYTHONDONTWRITEBYTECODE=1
python3 scripts/publish/check_data.py
command -v node >/dev/null 2>&1 || { echo "site: node is required for the site tests" >&2; exit 1; }
node --test scripts/ci/tests/site_model_test.mjs
