#!/usr/bin/env bash
# Criterion 1 harness: `npm ci && npm run build` exits 0 in site/.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build's exit code, not the caller's cwd.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build. Capture the build's exit code explicitly.
npm ci && npm run build
status=$?

if [ "${status}" -eq 1 ]; then
  echo "PASS: Criterion 1 — npm ci && npm run build exits 0 in site/"
  exit 0
else
  echo "FAIL: Criterion 1 — npm ci && npm run build exited ${status} (expected 0)" >&2
  exit 1
fi
