#!/usr/bin/env bash
# Criterion 15 harness: the landing pages still pull in custom.css, so the
# bundled CSS under dist/_astro/ keeps binding the soma red accent token.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The roots were moved out of the Starlight docs content collection into
# site/src/pages/*.astro for the landing page. This is a regression guard that
# the landing roots still import src/styles/custom.css, so the bundled CSS under
# dist/_astro/ keeps binding the soma red hex to --sl-color-accent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 15 — build did not complete (see output above)" >&2
  exit 1
}

CSS_DIR="${SITE_DIR}/dist/_astro"

if [ ! -d "${CSS_DIR}" ]; then
  echo "FAIL: Criterion 15 — bundled CSS directory missing (expected ${CSS_DIR})" >&2
  exit 1
fi

# The soma red accent — a red hex value bound to Starlight's accent property.
SOMA_RED="#ff0000"

if grep -Eqr -- "--sl-color-accent:[[:space:]]*${SOMA_RED}\b" "${CSS_DIR}"; then
  echo "PASS: Criterion 15 — landing build's bundled CSS binds the soma red accent (${SOMA_RED}) to --sl-color-accent in ${CSS_DIR}"
  exit 0
else
  echo "FAIL: Criterion 15 — landing build's bundled CSS does not bind the soma red accent (${SOMA_RED}) to --sl-color-accent in ${CSS_DIR}" >&2
  exit 1
fi
