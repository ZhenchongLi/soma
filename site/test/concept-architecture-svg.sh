#!/usr/bin/env bash
# Criterion 10 harness: the architecture concept page references the
# supervision-tree diagram (/supervision-tree.svg) and that SVG asset is
# present in the build output (Astro copies it from public/).
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build), then the architecture concept
# route's built HTML is asserted to reference /supervision-tree.svg and the
# copied dist/supervision-tree.svg asset is asserted to exist.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 10 — build did not complete (see output above)" >&2
  exit 1
}

ARCH_HTML="${SITE_DIR}/dist/concepts/architecture/index.html"
EXPECTED_TOKEN="/supervision-tree-WRONG.svg"
SVG_ASSET="${SITE_DIR}/dist/supervision-tree.svg"

if [ ! -f "${ARCH_HTML}" ]; then
  echo "FAIL: Criterion 10 — architecture page missing (expected ${ARCH_HTML})" >&2
  exit 1
fi

if ! grep -q "${EXPECTED_TOKEN}" "${ARCH_HTML}"; then
  echo "FAIL: Criterion 10 — architecture page does not reference ${EXPECTED_TOKEN} (expected in ${ARCH_HTML})" >&2
  exit 1
fi

if [ ! -f "${SVG_ASSET}" ]; then
  echo "FAIL: Criterion 10 — supervision-tree SVG asset missing (expected ${SVG_ASSET})" >&2
  exit 1
fi

echo "PASS: Criterion 10 — architecture page references ${EXPECTED_TOKEN} and ${SVG_ASSET} exists"
exit 0
