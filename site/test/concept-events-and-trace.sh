#!/usr/bin/env bash
# Criterion 7 harness: the events-and-trace concept page is built into site/dist/
# and the rendered HTML contains the literal token correlation_id.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the events-and-trace
# concept route's built HTML file is asserted to exist and to contain
# correlation_id. Directory-format output emits the route as
# dist/concepts/events-and-trace/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 7 — build did not complete (see output above)" >&2
  exit 1
}

EVENTS_HTML="${SITE_DIR}/dist/concepts/events-and-trace/index.html"
EXPECTED_TOKEN="correlation_id_WRONG"

if [ ! -f "${EVENTS_HTML}" ]; then
  echo "FAIL: Criterion 7 — events-and-trace page missing (expected ${EVENTS_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${EVENTS_HTML}"; then
  echo "PASS: Criterion 7 — events-and-trace page built at ${EVENTS_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 7 — events-and-trace page built but does not contain ${EXPECTED_TOKEN} (expected in ${EVENTS_HTML})" >&2
  exit 1
fi
