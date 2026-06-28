#!/usr/bin/env bash
# Criterion 7 harness: the Erlang/OTP primer reference page is built into
# site/dist/ and the rendered HTML contains the literal token gen_server.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the primer reference
# route's built HTML file is asserted to exist and to contain gen_server.
# Directory-format output emits the route as
# dist/reference/erlang-otp-primer/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: erlang-otp-primer reference — build did not complete (see output above)" >&2
  exit 1
}

PRIMER_HTML="${SITE_DIR}/dist/reference/erlang-otp-primer/index.html"
EXPECTED_TOKEN="gen_server"

if [ ! -f "${PRIMER_HTML}" ]; then
  echo "FAIL: erlang-otp-primer reference — page missing (expected ${PRIMER_HTML})" >&2
  exit 1
fi

if grep -q "${EXPECTED_TOKEN}" "${PRIMER_HTML}"; then
  echo "PASS: erlang-otp-primer reference — page built at ${PRIMER_HTML} and contains ${EXPECTED_TOKEN}"
  exit 0
else
  echo "FAIL: erlang-otp-primer reference — page built but does not contain ${EXPECTED_TOKEN} (expected in ${PRIMER_HTML})" >&2
  exit 1
fi
