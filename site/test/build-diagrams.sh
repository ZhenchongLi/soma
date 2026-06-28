#!/usr/bin/env bash
# Criterion 11 harness: the five architecture SVGs appear under site/public/
# and, after the build, under site/dist/.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then each named SVG is
# asserted to exist under BOTH site/public/ (the source) and site/dist/ (the
# built output). All must be found to PASS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 11 — build did not complete (see output above)" >&2
  exit 1
}

PUBLIC_DIR="${SITE_DIR}/public"
DIST_DIR="${SITE_DIR}/dist"

if [ ! -d "${DIST_DIR}" ]; then
  echo "FAIL: Criterion 11 — built output directory missing (expected ${DIST_DIR})" >&2
  exit 1
fi

# The five architecture SVGs that must be present in both public/ and dist/.
SVGS=(
  run-states.svg
  soma-actor-flow.svg
  soma-actor-loop.svg
  supervision-tree.svg
  tool-call.svg
)

for svg in "${SVGS[@]}"; do
  if [ ! -f "${PUBLIC_DIR}/${svg}" ]; then
    echo "FAIL: Criterion 11 — ${svg} missing from public/ (expected ${PUBLIC_DIR}/${svg})" >&2
    exit 1
  fi
  if [ ! -f "${DIST_DIR}/${svg}" ]; then
    echo "FAIL: Criterion 11 — ${svg} missing from dist/ (expected ${DIST_DIR}/${svg})" >&2
    exit 1
  fi
done

echo "PASS: Criterion 11 — all five architecture SVGs present in ${PUBLIC_DIR} and ${DIST_DIR}"
exit 0
