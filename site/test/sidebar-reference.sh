#!/usr/bin/env bash
# Criterion 10 harness: the rendered sidebar HTML contains a "Reference" group
# whose links point to both /reference/<slug>/ routes.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then a built docs page's HTML
# is asserted to contain the literal group label "Reference" and an href for
# each of the two /reference/<slug>/ routes. The sidebar is rendered into every
# docs page, so the architecture page is a representative entry point.
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
  echo "FAIL: Criterion 10 — build did not complete (see output above)" >&2
  exit 1
}

ENTRY_HTML="${SITE_DIR}/dist/concepts/architecture/index.html"

if [ ! -f "${ENTRY_HTML}" ]; then
  echo "FAIL: Criterion 10 — entry page missing (expected ${ENTRY_HTML})" >&2
  exit 1
fi

# The two Reference routes the sidebar group must link to.
REFERENCE_SLUGS=(
  roadmap
  erlang-otp-primer
)

missing=0

if ! grep -q "Reference" "${ENTRY_HTML}"; then
  echo "FAIL: Criterion 10 — sidebar group label 'Reference' absent from ${ENTRY_HTML}" >&2
  missing=1
fi

for slug in "${REFERENCE_SLUGS[@]}"; do
  if ! grep -q "href=\"/reference/${slug}/\"" "${ENTRY_HTML}"; then
    echo "FAIL: Criterion 10 — sidebar link to /reference/${slug}/ absent from ${ENTRY_HTML}" >&2
    missing=1
  fi
done

if [ "${missing}" -ne 0 ]; then
  exit 1
fi

echo "PASS: Criterion 10 — sidebar Reference group with both /reference/<slug>/ links present in ${ENTRY_HTML}"
exit 0
