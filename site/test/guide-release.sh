#!/usr/bin/env bash
# Criterion 5 harness: the Release guide page is built into site/dist/ and the
# rendered HTML contains the literal token rebar3 as prod.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the Release guide route's
# built HTML file is asserted to exist and to contain rebar3 as prod.
# Directory-format output emits the route as dist/guides/release/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: release guide — build did not complete (see output above)" >&2
  exit 1
}

RELEASE_HTML="${SITE_DIR}/dist/guides/release/index.html"
EXPECTED_TOKEN="rebar3 as prod"

if [ ! -f "${RELEASE_HTML}" ]; then
  echo "FAIL: release guide — page missing (expected ${RELEASE_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${RELEASE_HTML}"; then
  echo "PASS: release guide — page built at ${RELEASE_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: release guide — page built but does not contain ${EXPECTED_TOKEN} (expected in ${RELEASE_HTML})" >&2
  exit 1
fi
