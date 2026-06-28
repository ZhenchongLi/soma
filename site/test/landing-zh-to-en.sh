#!/usr/bin/env bash
# Criterion 6 harness: the Chinese landing root links back to the English root.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the built Chinese root
# dist/zh/index.html is asserted to contain an anchor whose href is /.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 6 — build did not complete (see output above)" >&2
  exit 1
}

ZH_ROOT="${SITE_DIR}/dist/zh/index.html"

if [ ! -f "${ZH_ROOT}" ]; then
  echo "FAIL: Criterion 6 — Chinese root route missing (expected ${ZH_ROOT})" >&2
  exit 1
fi

# The exact anchor href the Chinese root must carry to reach the English root.
LANG_LINK='href="/en-root-not-present/"'

if grep -qF -- "${LANG_LINK}" "${ZH_ROOT}"; then
  echo "PASS: Criterion 6 — Chinese root links back to the English root (${LANG_LINK}) in ${ZH_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 6 — Chinese root missing the English-root link (${LANG_LINK}) in ${ZH_ROOT}" >&2
  exit 1
fi
