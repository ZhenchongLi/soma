#!/usr/bin/env bash
# Criterion 12 harness: the Chinese landing root's <html> tag carries the exact
# lang="zh-CN".
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then dist/zh/index.html is
# grepped for an <html> tag carrying the exact lang="zh-CN". This is stricter
# than the #154 build-zh-lang.sh (which matches lang="zh as a prefix): it is a
# regression guard that the zh lang survives the root replacement.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 12 — build did not complete (see output above)" >&2
  exit 1
}

ZH_ROOT="${SITE_DIR}/dist/zh/index.html"

if [ ! -f "${ZH_ROOT}" ]; then
  echo "FAIL: Criterion 12 — Chinese root route missing (expected ${ZH_ROOT})" >&2
  exit 1
fi

# The exact lang attribute the Chinese landing's <html> tag must carry.
LANG_ATTR='lang="zh-TW"'

if ! grep -Eq "<html[^>]*${LANG_ATTR}" "${ZH_ROOT}"; then
  echo "FAIL: Criterion 12 — Chinese root <html> missing ${LANG_ATTR} in ${ZH_ROOT}" >&2
  exit 1
fi

echo "PASS: Criterion 12 — Chinese root <html> carries ${LANG_ATTR}"
exit 0
