#!/usr/bin/env bash
# Criterion 4 harness: the CLI guide page is built into site/dist/ and the
# rendered HTML contains the public task-form run input tokens.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the CLI guide route's
# built HTML file is asserted to exist and to contain the task-form run input
# language. Directory-format output emits the route as dist/guides/cli/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: cli guide — build did not complete (see output above)" >&2
  exit 1
}

CLI_HTML="${SITE_DIR}/dist/guides/cli/index.html"
EXPECTED_TOKENS=("soma run" "Soma Lisp source" "public static task form")

if [ ! -f "${CLI_HTML}" ]; then
  echo "FAIL: cli guide — page missing (expected ${CLI_HTML})" >&2
  exit 1
fi

for EXPECTED_TOKEN in "${EXPECTED_TOKENS[@]}"; do
  if ! grep -q "${EXPECTED_TOKEN}" "${CLI_HTML}"; then
    echo "FAIL: cli guide — page built but does not contain ${EXPECTED_TOKEN} (expected in ${CLI_HTML})" >&2
    exit 1
  fi
done

echo "PASS: cli guide — page built at ${CLI_HTML} and contains public task-form run input tokens"
exit 0
