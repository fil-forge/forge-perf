#!/usr/bin/env bash
# Runs shellcheck over every shell script in the repository.
#
# The host scripts run as root on a box nobody watches, so a quoting mistake in
# one of them loses a run or worse. CI pins shellcheck 0.11.0; a different
# local version can disagree, and the version line below says which one ran.
#
# -x follows `. lib.sh` and similar, and -P SCRIPTDIR lets it find a file
# sourced relative to the script, as infra-nodes' check does.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

scripts=()
while IFS= read -r -d '' file; do
  scripts+=("$file")
done < <(git ls-files -z --cached --others --exclude-standard -- '*.sh')

shellcheck --version | sed -n 's/^version: /shellcheck /p'
if [ "${#scripts[@]}" -eq 0 ]; then
  echo "shell: no scripts"
  exit 0
fi
shellcheck -x -P SCRIPTDIR "${scripts[@]}"
echo "shell: ${#scripts[@]} script(s) clean"
