#!/usr/bin/env bash
# Criterion 7 harness: the English landing references the supervision-tree SVG,
# and that SVG file is present in the build output.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then two things are asserted:
# (a) dist/index.html contains the literal asset path, and (b) the referenced
# SVG file actually exists in dist/.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 7 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 7 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The exact asset path the landing must reference.
SVG_REF="/supervision-tree.svg"
# The built SVG file the reference must resolve to.
SVG_FILE="${SITE_DIR}/dist/supervision-tree.svg"

if ! grep -qF -- "${SVG_REF}" "${EN_ROOT}"; then
  echo "FAIL: Criterion 7 — English root does not reference ${SVG_REF} in ${EN_ROOT}" >&2
  exit 1
fi

if [ ! -f "${SVG_FILE}" ]; then
  echo "FAIL: Criterion 7 — referenced SVG missing (expected ${SVG_FILE})" >&2
  exit 1
fi

echo "PASS: Criterion 7 — English root references ${SVG_REF} and ${SVG_FILE} exists"
exit 0
