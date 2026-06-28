#!/usr/bin/env bash
# Criterion 14 harness: the Chinese seed docs route survives the landing build.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The roots were moved out of the Starlight docs content collection into
# site/src/pages/*.astro for the landing page. This is a regression guard that
# the seed Chinese docs route still builds. Directory-format output emits the
# zh start/overview route as dist/zh/start/overview/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 14 — build did not complete (see output above)" >&2
  exit 1
}

ZH_DOCS="${SITE_DIR}/dist/zh/start/overview/NONEXISTENT/index.html"

if [ -f "${ZH_DOCS}" ]; then
  echo "PASS: Criterion 14 — Chinese seed docs route survives at ${ZH_DOCS}"
  exit 0
else
  echo "FAIL: Criterion 14 — Chinese seed docs route missing (expected ${ZH_DOCS})" >&2
  exit 1
fi
