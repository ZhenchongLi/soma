#!/usr/bin/env bash
# Criterion 4 harness: the Chinese landing root carries the hero phrase.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the built Chinese root
# dist/zh/index.html is asserted to contain the exact hero phrase.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 4 — build did not complete (see output above)" >&2
  exit 1
}

ZH_ROOT="${SITE_DIR}/dist/zh/index.html"

if [ ! -f "${ZH_ROOT}" ]; then
  echo "FAIL: Criterion 4 — Chinese root route missing (expected ${ZH_ROOT})" >&2
  exit 1
fi

# The exact hero phrase the Chinese landing must carry.
HERO_PHRASE="受监督的进程树"

if grep -qF -- "${HERO_PHRASE}" "${ZH_ROOT}"; then
  echo "PASS: Criterion 4 — Chinese root carries the hero phrase (${HERO_PHRASE}) in ${ZH_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 4 — Chinese root missing the hero phrase (${HERO_PHRASE}) in ${ZH_ROOT}" >&2
  exit 1
fi
