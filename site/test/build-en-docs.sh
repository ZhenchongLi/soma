#!/usr/bin/env bash
# Criterion 5 harness: the English seed docs route is built into site/dist/.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the English seed docs
# route's built HTML file is asserted to exist. Directory-format output emits
# the start/overview route as dist/start/overview/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 5 — build did not complete (see output above)" >&2
  exit 1
}

EN_DOCS="${SITE_DIR}/dist/start/overview/index.html"

if [ -f "${EN_DOCS}" ]; then
  echo "PASS: Criterion 5 — English seed docs route built at ${EN_DOCS}"
  exit 0
else
  echo "FAIL: Criterion 5 — English seed docs route missing (expected ${EN_DOCS})" >&2
  exit 1
fi
