#!/usr/bin/env bash
# Mint a GitHub App installation token that reads the harness repository.
#
#   harness-token.sh PARAM DIR
#
# PARAM names an SSM SecureString holding {"app_id", "installation_id",
# "private_key"} for a GitHub App installed on fil-one/storage-qualification
# alone, with read access to its contents. Writes DIR/harness-token (mode
# 0600). The token lasts an hour, which covers a checkout. The App's key never
# leaves DIR, which the wipe deletes.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: harness-token.sh PARAM DIR" >&2; exit 2; }
param="$1" dir="$2"
api="${FORGE_PERF_GITHUB_API:-https://api.github.com}"
umask 077
trap 'rm -f "$dir/harness-app.json" "$dir/harness-app.pem" "$dir/harness-app.header" "$dir/harness-token.tmp"' EXIT

aws ssm get-parameter --with-decryption --name "$param" --query Parameter.Value --output text \
  >"$dir/harness-app.json"
app="$(jq -r '.app_id // empty' "$dir/harness-app.json")"
installation="$(jq -r '.installation_id // empty' "$dir/harness-app.json")"
jq -r '.private_key // empty' "$dir/harness-app.json" >"$dir/harness-app.pem"
if ! [[ "$app" =~ ^[0-9]+$ && "$installation" =~ ^[0-9]+$ && -s "$dir/harness-app.pem" ]]; then
  echo "harness-token.sh: $param lacks app_id, installation_id or private_key" >&2
  exit 1
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now="$(date +%s)"
# GitHub accepts an App JWT for at most 10 minutes; iat a minute back allows for clock drift.
unsigned="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url).$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
  $((now - 60)) $((now + 540)) "$app" | b64url)"
signature="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$dir/harness-app.pem" | b64url)"
# The header goes through a file, so the JWT never shows in the process list.
printf 'Authorization: Bearer %s.%s\n' "$unsigned" "$signature" >"$dir/harness-app.header"
curl -fsS -m 30 -X POST -H @"$dir/harness-app.header" -H 'Accept: application/vnd.github+json' \
  "$api/app/installations/$installation/access_tokens" | jq -er '.token' >"$dir/harness-token.tmp"
mv "$dir/harness-token.tmp" "$dir/harness-token"
