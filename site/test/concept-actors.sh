#!/usr/bin/env bash
# Criterion 5 harness: the actors concept page is built into site/dist/
# and the rendered HTML contains the literal token soma_actor.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the actors concept
# route's built HTML file is asserted to exist and to contain soma_actor.
# Directory-format output emits the route as dist/concepts/actors/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 5 — build did not complete (see output above)" >&2
  exit 1
}

ACTORS_HTML="${SITE_DIR}/dist/concepts/actors/index.html"
EXPECTED_TOKEN="soma_actor"

if [ ! -f "${ACTORS_HTML}" ]; then
  echo "FAIL: Criterion 5 — actors page missing (expected ${ACTORS_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${ACTORS_HTML}"; then
  echo "PASS: Criterion 5 — actors page built at ${ACTORS_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 5 — actors page built but does not contain ${EXPECTED_TOKEN} (expected in ${ACTORS_HTML})" >&2
  exit 1
fi
