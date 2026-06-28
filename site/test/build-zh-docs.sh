#!/usr/bin/env bash
# Criterion 6 harness: the Chinese seed docs route is built into site/dist/.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the Chinese seed docs
# route's built HTML file is asserted to exist. Directory-format output emits
# the zh start/overview route as dist/zh/start/overview/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 6 — build did not complete (see output above)" >&2
  exit 1
}

ZH_DOCS="${SITE_DIR}/dist/zh/start/overview/index.html"

if [ -f "${ZH_DOCS}" ]; then
  echo "PASS: Criterion 6 — Chinese seed docs route built at ${ZH_DOCS}"
  exit 0
else
  echo "FAIL: Criterion 6 — Chinese seed docs route missing (expected ${ZH_DOCS})" >&2
  exit 1
fi
