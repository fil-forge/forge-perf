#!/usr/bin/env bash
# Watches publish.yml from campaign-reaper.yml, the one other scheduled
# workflow. publish.yml posts every run alert, so when it fails or its
# schedule is disabled nothing else says so. It runs every 15 minutes; this
# prints one alert line when its newest successful run on main is more than
# 2 hours old, or when it has none.
#
# Needs gh with GH_TOKEN (actions: read) and GITHUB_REPOSITORY. NOW (Unix
# seconds) replaces the clock in tests.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
now="${NOW:-$(date -u +%s)}"
runs="$repo/actions/workflows/publish.yml"

last="$(gh run list -R "$repo" --workflow publish.yml --branch main --status success --limit 1 \
  --json updatedAt -q '.[0].updatedAt // ""')"
if [ -z "$last" ]; then
  echo "forge-perf: publish.yml has no successful run on main; check SLACK_BOT_TOKEN, the role trust and whether the workflow is disabled (gh workflow list --all): https://github.com/$runs"
  exit 0
fi
at="$(jq -rn --arg t "$last" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')"
if [ $((now - at)) -gt 7200 ]; then
  echo "forge-perf: publish.yml last succeeded at $last; check SLACK_BOT_TOKEN, the role trust and whether the workflow is disabled (gh workflow list --all): https://github.com/$runs"
fi
