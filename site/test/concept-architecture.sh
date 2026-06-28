#!/usr/bin/env bash
# Criterion 2 harness: the architecture concept page is built into site/dist/
# and the rendered HTML contains the literal token soma_run.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the architecture concept
# route's built HTML file is asserted to exist and to contain soma_run.
# Directory-format output emits the route as
# dist/concepts/architecture/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 2 — build did not complete (see output above)" >&2
  exit 1
}

ARCH_HTML="${SITE_DIR}/dist/concepts/architecture/index.html"
EXPECTED_TOKEN="soma_run"

if [ ! -f "${ARCH_HTML}" ]; then
  echo "FAIL: Criterion 2 — architecture page missing (expected ${ARCH_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${ARCH_HTML}"; then
  echo "PASS: Criterion 2 — architecture page built at ${ARCH_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 2 — architecture page built but does not contain ${EXPECTED_TOKEN} (expected in ${ARCH_HTML})" >&2
  exit 1
fi
