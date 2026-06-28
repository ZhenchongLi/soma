#!/usr/bin/env bash
# Criterion 8 harness: the rendered English page includes a language-switcher
# control that links to the /zh/ locale.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the English root route's
# built HTML is asserted to contain Starlight's language-picker control
# (<starlight-lang-select>) holding an option that links into the /zh/ locale.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 8 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 8 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

if grep -Eq 'starlight-lang-select' "${EN_ROOT}" \
   && grep -Eq '<option[^>]*value="/zh-TW/"' "${EN_ROOT}"; then
  echo "PASS: Criterion 8 — English page has a language switcher linking to the locale in ${EN_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 8 — English page lacks a language switcher linking to the locale in ${EN_ROOT}" >&2
  exit 1
fi
