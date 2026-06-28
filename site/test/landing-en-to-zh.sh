#!/usr/bin/env bash
# Criterion 5 harness: the English landing root links to the Chinese locale.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the built English root
# dist/index.html is asserted to contain an anchor whose href is /zh/.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 5 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 5 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The exact anchor href the English root must carry to reach the Chinese locale.
LANG_LINK='href="/zh/"'

if grep -qF -- "${LANG_LINK}" "${EN_ROOT}"; then
  echo "PASS: Criterion 5 — English root links to the Chinese locale (${LANG_LINK}) in ${EN_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 5 — English root missing the Chinese-locale link (${LANG_LINK}) in ${EN_ROOT}" >&2
  exit 1
fi
