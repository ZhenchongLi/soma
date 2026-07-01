#!/usr/bin/env bash
# Criterion 5 harness: the Roadmap reference page is built into site/dist/ and the
# rendered HTML contains the literal token for bounded Soma Lisp v1.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the Roadmap reference
# route's built HTML file is asserted to exist and to contain bounded Soma Lisp v1.
# Directory-format output emits the route as dist/reference/roadmap/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: roadmap reference — build did not complete (see output above)" >&2
  exit 1
}

ROADMAP_HTML="${SITE_DIR}/dist/reference/roadmap/index.html"
EXPECTED_TOKEN="bounded Soma Lisp v1"

if [ ! -f "${ROADMAP_HTML}" ]; then
  echo "FAIL: roadmap reference — page missing (expected ${ROADMAP_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${ROADMAP_HTML}"; then
  echo "PASS: roadmap reference — page built at ${ROADMAP_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: roadmap reference — page built but does not contain ${EXPECTED_TOKEN} (expected in ${ROADMAP_HTML})" >&2
  exit 1
fi
