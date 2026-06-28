#!/usr/bin/env bash
# Criterion 7 harness: a built Chinese page carries a zh lang attribute on its
# <html> element.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the Chinese root route's
# built HTML is asserted to carry lang="zh-TW" on its <html> element.
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

ZH_ROOT="${SITE_DIR}/dist/zh/index.html"

if [ ! -f "${ZH_ROOT}" ]; then
  echo "FAIL: Criterion 7 — Chinese root route missing (expected ${ZH_ROOT})" >&2
  exit 1
fi

if grep -Eq '<html[^>]*lang="zh-TW"' "${ZH_ROOT}"; then
  echo "PASS: Criterion 7 — Chinese page carries a zh lang attribute on <html> in ${ZH_ROOT}"
  exit 0
else
  echo "FAIL: Criterion 7 — Chinese page <html> lacks a zh lang attribute in ${ZH_ROOT}" >&2
  exit 1
fi
