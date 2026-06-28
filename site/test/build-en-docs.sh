#!/usr/bin/env bash
# Criterion 13 harness: the existing overview route still builds to
# site/dist/start/overview/index.html after the explicit-sidebar change.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the overview route's
# built HTML file is asserted to exist. Directory-format output emits the
# start/overview route as dist/start/overview/index.html. This doubles as the
# regression guard that switching the Starlight sidebar to an explicit array did
# not break the existing overview route.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 13 — build did not complete (see output above)" >&2
  exit 1
}

OVERVIEW="${SITE_DIR}/dist/start/quick-start/index.html"

if [ -f "${OVERVIEW}" ]; then
  echo "PASS: Criterion 13 — overview route built at ${OVERVIEW}"
  exit 0
else
  echo "FAIL: Criterion 13 — overview route missing (expected ${OVERVIEW})" >&2
  exit 1
fi
