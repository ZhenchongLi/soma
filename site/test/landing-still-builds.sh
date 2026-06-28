#!/usr/bin/env bash
# Criterion 12 harness: the landing route still builds into site/dist/.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the landing route's
# built HTML file is asserted to exist. This guards the landing route against
# the explicit-sidebar config change. Astro emits the landing page from
# src/pages/index.astro as dist/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 12 — build did not complete (see output above)" >&2
  exit 1
}

LANDING_HTML="${SITE_DIR}/dist/index.html"

if [ -f "${LANDING_HTML}" ]; then
  echo "PASS: Criterion 12 — landing route built at ${LANDING_HTML}"
  exit 0
else
  echo "FAIL: Criterion 12 — landing route missing (expected ${LANDING_HTML})" >&2
  exit 1
fi
