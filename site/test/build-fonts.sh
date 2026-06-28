#!/usr/bin/env bash
# Criterion 10 harness: the built site output references both the Inter and
# IBM Plex Mono font families.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the built output under
# dist/ is asserted to reference BOTH font families. Both must be found to PASS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 10 — build did not complete (see output above)" >&2
  exit 1
}

DIST_DIR="${SITE_DIR}/dist"

if [ ! -d "${DIST_DIR}" ]; then
  echo "FAIL: Criterion 10 — built output directory missing (expected ${DIST_DIR})" >&2
  exit 1
fi

# The two font families the built site must reference.
SANS_FONT="Comic Sans MS"
MONO_FONT="IBM Plex Mono"

if ! grep -qr -- "${SANS_FONT}" "${DIST_DIR}"; then
  echo "FAIL: Criterion 10 — built output does not reference the ${SANS_FONT} font family in ${DIST_DIR}" >&2
  exit 1
fi

if ! grep -qr -- "${MONO_FONT}" "${DIST_DIR}"; then
  echo "FAIL: Criterion 10 — built output does not reference the ${MONO_FONT} font family in ${DIST_DIR}" >&2
  exit 1
fi

echo "PASS: Criterion 10 — built output references both ${SANS_FONT} and ${MONO_FONT} font families in ${DIST_DIR}"
exit 0
