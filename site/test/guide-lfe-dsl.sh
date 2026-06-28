#!/usr/bin/env bash
# Criterion 3 harness: the LFE DSL guide page is built into site/dist/ and the
# rendered HTML contains the literal token soma_lfe.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the LFE DSL guide route's
# built HTML file is asserted to exist and to contain soma_lfe. Directory-format
# output emits the route as dist/guides/lfe-dsl/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: lfe-dsl guide — build did not complete (see output above)" >&2
  exit 1
}

LFE_DSL_HTML="${SITE_DIR}/dist/guides/lfe-dsl/index.html"
EXPECTED_TOKEN="soma_lfe"

if [ ! -f "${LFE_DSL_HTML}" ]; then
  echo "FAIL: lfe-dsl guide — page missing (expected ${LFE_DSL_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${LFE_DSL_HTML}"; then
  echo "PASS: lfe-dsl guide — page built at ${LFE_DSL_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: lfe-dsl guide — page built but does not contain ${EXPECTED_TOKEN} (expected in ${LFE_DSL_HTML})" >&2
  exit 1
fi
