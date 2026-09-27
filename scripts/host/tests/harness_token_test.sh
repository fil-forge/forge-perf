#!/usr/bin/env bash
# harness-token.sh against a stubbed SSM and GitHub API: the App JWT it sends
# must verify with the App's public key, and only the token may remain.
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/token-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export W="$work"
mkdir -p "$work/bin" "$work/secrets"
fail() { echo "FAIL: $*" >&2; exit 1; }

openssl genrsa -out "$work/app.pem" 2048 2>/dev/null
openssl rsa -in "$work/app.pem" -pubout -out "$work/app.pub" 2>/dev/null
jq -n --rawfile key "$work/app.pem" '{app_id: "123456", installation_id: "7890", private_key: $key}' >"$work/param"
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"--name /forge-perf/harness-app "*) cat "$W/param" ;; *) exit 254 ;; esac
STUB
# Keeps the Authorization header and the URL, answers like GitHub.
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a; do
  case "$a" in @*) cp "${a#@}" "$W/header" ;; https://*) echo "$a" >"$W/url" ;; esac
done
while [ $# -gt 0 ]; do [ "$1" != -d ] || printf '%s' "$2" >"$W/body"; shift; done
[ -z "${API_DOWN:-}" ] || exit 22
echo '{"token": "ghs_testtoken", "expires_at": "2026-10-01T13:00:00Z"}'
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

"$host/harness-token.sh" /forge-perf/harness-app "$work/secrets" fil-one/storage-qualification
[ "$(cat "$work/secrets/harness-token")" = ghs_testtoken ] || fail "token"
[ "$(cat "$work/url")" = https://api.github.com/app/installations/7890/access_tokens ] || fail "url $(cat "$work/url")"
jq -e '. == {repositories: ["storage-qualification"], permissions: {contents: "read"}}' "$work/body" >/dev/null ||
  fail "token scope $(cat "$work/body")"
[ "$(command ls "$work/secrets")" = harness-token ] || fail "left: $(command ls "$work/secrets")"
case "$(stat -c %a "$work/secrets/harness-token" 2>/dev/null || stat -f %Lp "$work/secrets/harness-token")" in
  600) ;; *) fail "token file mode" ;;
esac
jwt="$(sed -n 's/^Authorization: Bearer //p' "$work/header")"
IFS=. read -r h p s <<<"$jwt"
unb64() { local x="$1"; while [ $((${#x} % 4)) -ne 0 ]; do x="$x="; done; tr -- '-_' '+/' <<<"$x" | openssl base64 -d -A; }
[ "$(unb64 "$h" | jq -c .)" = '{"alg":"RS256","typ":"JWT"}' ] || fail "header"
unb64 "$p" | jq -e '.iss == "123456" and .exp - .iat == 600' >/dev/null || fail "claims $(unb64 "$p")"
printf '%s' "$h.$p" >"$work/signed"
unb64 "$s" >"$work/sig"
openssl dgst -sha256 -verify "$work/app.pub" -signature "$work/sig" "$work/signed" >/dev/null || fail "signature"
echo "ok: the App JWT verifies, the token is scoped to the one repository's contents, and only the token stays"

rm -f "$work/secrets/harness-token"
if API_DOWN=1 "$host/harness-token.sh" /forge-perf/harness-app "$work/secrets" fil-one/storage-qualification 2>/dev/null; then fail "API down succeeded"; fi
[ -z "$(command ls "$work/secrets")" ] || fail "left after a failure: $(command ls "$work/secrets")"
echo "ok: a failed token request leaves nothing behind"
