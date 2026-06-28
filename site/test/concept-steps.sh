#!/usr/bin/env bash
# Criterion 3 harness: the steps concept page is built into site/dist/
# and the rendered HTML contains the literal token from_step.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the steps concept
# route's built HTML file is asserted to exist and to contain from_step.
# Directory-format output emits the route as dist/concepts/steps/index.html.
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

STEPS_HTML="${SITE_DIR}/dist/concepts/steps/index.html"
EXPECTED_TOKEN="from_step"

if [ ! -f "${STEPS_HTML}" ]; then
  echo "FAIL: Criterion 3 — steps page missing (expected ${STEPS_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${STEPS_HTML}"; then
  echo "PASS: Criterion 3 — steps page built at ${STEPS_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 3 — steps page built but does not contain ${EXPECTED_TOKEN} (expected in ${STEPS_HTML})" >&2
  exit 1
fi
