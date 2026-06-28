#!/usr/bin/env bash
# Criterion 6 harness: the decision-layer concept page is built into site/dist/
# and the rendered HTML contains the literal token policy.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the decision-layer
# concept route's built HTML file is asserted to exist and to contain policy.
# Directory-format output emits the route as
# dist/concepts/decision-layer/index.html.
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

DECISION_HTML="${SITE_DIR}/dist/concepts/decision-layer/index.html"
EXPECTED_TOKEN="policy"

if [ ! -f "${DECISION_HTML}" ]; then
  echo "FAIL: Criterion 6 — decision-layer page missing (expected ${DECISION_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${DECISION_HTML}"; then
  echo "PASS: Criterion 6 — decision-layer page built at ${DECISION_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 6 — decision-layer page built but does not contain ${EXPECTED_TOKEN} (expected in ${DECISION_HTML})" >&2
  exit 1
fi
