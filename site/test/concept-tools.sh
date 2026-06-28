#!/usr/bin/env bash
# Criterion 4 harness: the tools concept page is built into site/dist/
# and the rendered HTML contains the literal token manifest.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the tools concept
# route's built HTML file is asserted to exist and to contain manifest.
# Directory-format output emits the route as dist/concepts/tools/index.html.
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

TOOLS_HTML="${SITE_DIR}/dist/concepts/tools/index.html"
EXPECTED_TOKEN="manifest"

if [ ! -f "${TOOLS_HTML}" ]; then
  echo "FAIL: Criterion 4 — tools page missing (expected ${TOOLS_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${TOOLS_HTML}"; then
  echo "PASS: Criterion 4 — tools page built at ${TOOLS_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 4 — tools page built but does not contain ${EXPECTED_TOKEN} (expected in ${TOOLS_HTML})" >&2
  exit 1
fi
