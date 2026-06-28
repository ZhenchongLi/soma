#!/usr/bin/env bash
# Criterion 8 harness: the durability concept page is built into site/dist/
# and the rendered HTML contains the literal token disk_log.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the durability
# concept route's built HTML file is asserted to exist and to contain
# disk_log. Directory-format output emits the route as
# dist/concepts/durability/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 8 — build did not complete (see output above)" >&2
  exit 1
}

DURABILITY_HTML="${SITE_DIR}/dist/concepts/durability/index.html"
EXPECTED_TOKEN="disk_log_DOES_NOT_EXIST"

if [ ! -f "${DURABILITY_HTML}" ]; then
  echo "FAIL: Criterion 8 — durability page missing (expected ${DURABILITY_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${DURABILITY_HTML}"; then
  echo "PASS: Criterion 8 — durability page built at ${DURABILITY_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 8 — durability page built but does not contain ${EXPECTED_TOKEN} (expected in ${DURABILITY_HTML})" >&2
  exit 1
fi
