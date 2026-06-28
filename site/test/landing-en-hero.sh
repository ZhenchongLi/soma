#!/usr/bin/env bash
# Criterion 2 harness: the English landing root carries the hero phrase.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the built English root
# dist/index.html is asserted to contain the exact hero phrase.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 2 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 2 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The exact hero phrase the landing must carry.
HERO_PHRASE="supervised OTP process tree"

if grep -qF -- "${HERO_PHRASE}" "${EN_ROOT}"; then
  echo "PASS: Criterion 2 — English root carries the hero phrase (${HERO_PHRASE}) in ${EN_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 2 — English root missing the hero phrase (${HERO_PHRASE}) in ${EN_ROOT}" >&2
  exit 1
fi
