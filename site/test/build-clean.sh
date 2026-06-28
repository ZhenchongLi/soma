#!/usr/bin/env bash
# Criterion 2 harness: `npm run build` emits a clean log in site/ —
# no error lines and no Starlight/Astro warning lines.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build's output text, not the caller's cwd.
#
# The build is run and its combined stdout+stderr is captured, then scanned for
# any line matching `error` or `warning` (case-insensitive). A clean build emits
# none; a Soma-caused misconfiguration would surface as a warning/error line.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Run the build, capturing combined stdout+stderr. We do not gate on the build's
# own exit code here (that is Criterion 1) — this harness is purely about output
# cleanliness.
log="$(npm run build 2>&1)"

# Scan for any line matching the pattern (case-insensitive). A clean build has
# none.
SCAN_PATTERN='error|warning'

if printf '%s\n' "${log}" | grep -niE "${SCAN_PATTERN}" >&2; then
  echo "FAIL: Criterion 2 — build output contains error/warning line(s) (shown above)" >&2
  exit 1
else
  echo "PASS: Criterion 2 — build output has no error or warning lines"
  exit 0
fi
