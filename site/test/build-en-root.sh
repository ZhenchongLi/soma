#!/usr/bin/env bash
# Criterion 3 harness: the English root route is built into site/dist/.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the English root route's
# built HTML file is asserted to exist. Directory-format output emits the root
# route as dist/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 3 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ -f "${EN_ROOT}" ]; then
  echo "PASS: Criterion 3 — English root route built at ${EN_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 3 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi
