#!/usr/bin/env bash
# Criterion 3 harness: the built English landing root carries the thesis phrase.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the built English root
# dist/index.html is asserted to contain the exact thesis phrase. The old
# Starlight splash never had this string, so a pass means the built root is the
# custom landing and not the scaffold splash.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 3 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 3 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The exact thesis phrase the landing must carry.
THESIS_PHRASE="agents fail in operational ways"

if grep -qF -- "${THESIS_PHRASE}" "${EN_ROOT}"; then
  echo "PASS: Criterion 3 — English root carries the thesis phrase (${THESIS_PHRASE}) in ${EN_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 3 — English root missing the thesis phrase (${THESIS_PHRASE}) in ${EN_ROOT}" >&2
  exit 1
fi
