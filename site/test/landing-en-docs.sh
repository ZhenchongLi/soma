#!/usr/bin/env bash
# Criterion 13 harness: the English seed docs route survives the landing build.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The roots were moved out of the Starlight docs content collection into
# site/src/pages/*.astro for the landing page. This is a regression guard that
# the seed English docs route still builds. Directory-format output emits the
# start/overview route as dist/start/overview/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 13 — build did not complete (see output above)" >&2
  exit 1
}

EN_DOCS="${SITE_DIR}/dist/start/overview/THIS_PATH_DOES_NOT_EXIST.html"

if [ -f "${EN_DOCS}" ]; then
  echo "PASS: Criterion 13 — English seed docs route survives at ${EN_DOCS}"
  exit 0
else
  echo "FAIL: Criterion 13 — English seed docs route missing (expected ${EN_DOCS})" >&2
  exit 1
fi
