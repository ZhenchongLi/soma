#!/usr/bin/env bash
# Criterion 4 harness: the Chinese root route is built into site/dist/.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the Chinese root route's
# built HTML file is asserted to exist. Directory-format output emits the zh
# root route as dist/zh/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 4 — build did not complete (see output above)" >&2
  exit 1
}

ZH_ROOT="${SITE_DIR}/dist/zh/index-zh.html"

if [ -f "${ZH_ROOT}" ]; then
  echo "PASS: Criterion 4 — Chinese root route built at ${ZH_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 4 — Chinese root route missing (expected ${ZH_ROOT})" >&2
  exit 1
fi
