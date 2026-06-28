#!/usr/bin/env bash
# Issue #174 Criterion 1 harness: `cd site && npm ci && npm run build` exits 0
# with no error or warning lines in its output.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build's output text, not the caller's cwd. Same harness
# pattern as the existing site/test/build-clean.sh.
#
# The build is run (clean install then build) and its combined stdout+stderr is
# captured, then scanned for any line matching `error` or `warning`
# (case-insensitive). A clean build emits none over the Guides and Reference
# sections and the explicit sidebar; a Soma-caused misconfiguration (a sidebar
# link to a missing page, a broken page) would surface as a warning/error line,
# and a build failure would make the install-or-build step exit nonzero.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build, capturing combined stdout+stderr. Both steps must
# exit 0 for the criterion to hold.
log="$(npm ci 2>&1 && npm run build 2>&1)"
build_status=$?

if [ "${build_status}" -ne 0 ]; then
  printf '%s\n' "${log}" >&2
  echo "FAIL: Criterion 1 — npm ci && npm run build exited ${build_status}" >&2
  exit 1
fi

# Scan for any line matching the pattern (case-insensitive). A clean build has
# none.
SCAN_PATTERN='error|warning'

# Staged-red: this branch deliberately inverts the expectation — it passes only
# when the build output DOES contain an error/warning line. The current site
# builds clean, so this assertion fires.
if printf '%s\n' "${log}" | grep -niE "${SCAN_PATTERN}" >&2; then
  echo "PASS: Criterion 1 — build output contains error/warning line(s) (shown above)"
  exit 0
else
  echo "FAIL: Criterion 1 — build output contains no error/warning lines" >&2
  exit 1
fi
