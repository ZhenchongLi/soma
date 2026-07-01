#!/usr/bin/env bash
# Criterion 2 harness: the usage guide page is built into site/dist/ and the
# rendered HTML contains the literal token start_run and the task-form wire
# summary.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the usage guide route's
# built HTML file is asserted to exist and to contain the usage guide's core
# runtime token and task-form wire summary. Directory-format output emits the
# route as dist/guides/usage/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: usage guide — build did not complete (see output above)" >&2
  exit 1
}

USAGE_HTML="${SITE_DIR}/dist/guides/usage/index.html"
EXPECTED_TOKENS=("start_run" "(task ...)" "public static task")

if [ ! -f "${USAGE_HTML}" ]; then
  echo "FAIL: usage guide — page missing (expected ${USAGE_HTML})" >&2
  exit 1
fi

for EXPECTED_TOKEN in "${EXPECTED_TOKENS[@]}"; do
  if ! grep -q "${EXPECTED_TOKEN}" "${USAGE_HTML}"; then
    echo "FAIL: usage guide — page built but does not contain ${EXPECTED_TOKEN} (expected in ${USAGE_HTML})" >&2
    exit 1
  fi
done

echo "PASS: usage guide — page built at ${USAGE_HTML} and contains task-form wire summary"
exit 0
