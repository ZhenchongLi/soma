#!/usr/bin/env bash
# Criterion 9 harness: the rendered sidebar HTML contains a "Guides" group
# whose links point to each of the four /guides/<slug>/ routes.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then a built docs page's HTML
# is asserted to contain the literal group label "Guides" and an href for each
# of the four /guides/<slug>/ routes. The sidebar is rendered into every docs
# page, so the architecture page is a representative entry point.
# Directory-format output emits the route as
# dist/concepts/architecture/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 9 — build did not complete (see output above)" >&2
  exit 1
}

ENTRY_HTML="${SITE_DIR}/dist/concepts/architecture/index.html"

if [ ! -f "${ENTRY_HTML}" ]; then
  echo "FAIL: Criterion 9 — entry page missing (expected ${ENTRY_HTML})" >&2
  exit 1
fi

# The four Guides routes the sidebar group must link to.
GUIDE_SLUGS=(
  usage
  lfe-dsl
  cli
  release
)

missing=0

if ! grep -q "Guides" "${ENTRY_HTML}"; then
  echo "FAIL: Criterion 9 — sidebar group label 'Guides' absent from ${ENTRY_HTML}" >&2
  missing=1
fi

for slug in "${GUIDE_SLUGS[@]}"; do
  if ! grep -q "href=\"/guides/${slug}/\"" "${ENTRY_HTML}"; then
    echo "FAIL: Criterion 9 — sidebar link to /guides/${slug}/ absent from ${ENTRY_HTML}" >&2
    missing=1
  fi
done

if [ "${missing}" -ne 0 ]; then
  exit 1
fi

echo "PASS: Criterion 9 — sidebar Guides group with all four /guides/<slug>/ links present in ${ENTRY_HTML}"
exit 0
