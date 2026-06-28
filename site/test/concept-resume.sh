#!/usr/bin/env bash
# Criterion 9 harness: the resume concept page is built into site/dist/
# and the rendered HTML contains the literal token run.started.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the resume
# concept route's built HTML file is asserted to exist and to contain
# run.started. Directory-format output emits the route as
# dist/concepts/resume/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 9 — build did not complete (see output above)" >&2
  exit 1
}

RESUME_HTML="${SITE_DIR}/dist/concepts/resume/index.html"
EXPECTED_TOKEN="WRONG_TOKEN_run_started_xyz"

if [ ! -f "${RESUME_HTML}" ]; then
  echo "FAIL: Criterion 9 — resume page missing (expected ${RESUME_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${RESUME_HTML}"; then
  echo "PASS: Criterion 9 — resume page built at ${RESUME_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: Criterion 9 — resume page built but does not contain ${EXPECTED_TOKEN} (expected in ${RESUME_HTML})" >&2
  exit 1
fi
