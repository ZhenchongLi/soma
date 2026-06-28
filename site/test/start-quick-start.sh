#!/usr/bin/env bash
# Criterion 3 harness (test_quick_start_has_rebar3): the quick-start docs page is
# built into site/dist/ and the rendered HTML carries the token rebar3.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the quick-start route's
# built HTML file is asserted to exist and to contain rebar3. Directory-format
# output emits the route as dist/start/quick-start/index.html.
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

QUICK_START_HTML="${SITE_DIR}/dist/start/quick-start/index.html"
EXPECTED_TOKEN="rebar3"

if [ ! -f "${QUICK_START_HTML}" ]; then
  echo "FAIL: Criterion 3 — quick-start page missing (expected ${QUICK_START_HTML})" >&2
  exit 1
fi

if grep -qF -- "${EXPECTED_TOKEN}" "${QUICK_START_HTML}"; then
  echo "PASS: Criterion 3 — quick-start page built at ${QUICK_START_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 3 — quick-start page built but does not contain ${EXPECTED_TOKEN} (expected in ${QUICK_START_HTML})" >&2
  exit 1
fi
