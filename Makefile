# The checks CI runs, so the same commands are available before pushing.
#
# `check` runs every scripts/ci/check-*.sh in name order and stops at the first
# failure. A new area adds its own check-<area>.sh rather than editing this file
# or the workflow, which is what keeps local runs and CI from drifting.
#
# The denylist check reads its pattern from PUBLIC_DENYLIST_REGEX or from the
# file named by DENYLIST_FILE, and skips with a notice when neither is set:
#
#   DENYLIST_FILE=/path/to/denylist.regex make check

# bash for pipefail and the loop. The make macOS ships is 3.81, which ignores
# .SHELLFLAGS, so the recipe sets the flags itself.
SHELL := /bin/bash

.PHONY: check
check:
	@set -euo pipefail; \
	export LC_ALL=C; \
	for script in scripts/ci/check-*.sh; do \
	  echo "==> $$script"; \
	  bash "$$script"; \
	done
