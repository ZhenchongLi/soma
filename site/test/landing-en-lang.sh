#!/usr/bin/env bash
# Criterion 11 harness: the English landing root's <html> tag carries lang="en".
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then dist/index.html is grepped
# for an <html> tag carrying lang="en".
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

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 11 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The exact lang attribute the English landing's <html> tag must carry.
LANG_ATTR='lang="en-WRONG"'

if ! grep -qF -- "${LANG_ATTR}" "${EN_ROOT}"; then
  echo "FAIL: Criterion 11 — English root <html> missing ${LANG_ATTR} in ${EN_ROOT}" >&2
  exit 1
fi

echo "PASS: Criterion 11 — English root <html> carries ${LANG_ATTR}"
exit 0
