#!/usr/bin/env bash
# Criterion 9 harness: the built CSS binds the soma red accent token — a red hex
# value bound to Starlight's accent custom property (--sl-color-accent).
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the bundled CSS under
# dist/_astro/ is asserted to bind the soma red hex to --sl-color-accent.
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

CSS_DIR="${SITE_DIR}/dist/_astro"

if [ ! -d "${CSS_DIR}" ]; then
  echo "FAIL: Criterion 9 — bundled CSS directory missing (expected ${CSS_DIR})" >&2
  exit 1
fi

# The soma red accent — a red hex value bound to Starlight's accent property.
SOMA_RED="#ff0000"

if grep -Eqr -- "--sl-color-accent:[[:space:]]*${SOMA_RED}\b" "${CSS_DIR}"; then
  echo "PASS: Criterion 9 — built CSS binds the soma red accent (${SOMA_RED}) to --sl-color-accent in ${CSS_DIR}"
  exit 0
else
  echo "FAIL: Criterion 9 — built CSS does not bind the soma red accent (${SOMA_RED}) to --sl-color-accent in ${CSS_DIR}" >&2
  exit 1
fi
