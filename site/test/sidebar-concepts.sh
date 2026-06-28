#!/usr/bin/env bash
# Criterion 11 harness: the rendered sidebar HTML contains a "Concepts" group
# whose links point to each of the eight /concepts/<slug>/ routes.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then a built docs page's HTML
# is asserted to contain the literal group label "Concepts" and an href for each
# of the eight /concepts/<slug>/ routes. The sidebar is rendered into every
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
  echo "FAIL: Criterion 11 — build did not complete (see output above)" >&2
  exit 1
}

ENTRY_HTML="${SITE_DIR}/dist/concepts/architecture/index.html"

if [ ! -f "${ENTRY_HTML}" ]; then
  echo "FAIL: Criterion 11 — entry page missing (expected ${ENTRY_HTML})" >&2
  exit 1
fi

# The eight Concepts routes the sidebar group must link to.
CONCEPT_SLUGS=(
  nonexistent
  steps
  tools
  actors
  decision-layer
  events-and-trace
  durability
  resume
)

missing=0

if ! grep -q "Concepts" "${ENTRY_HTML}"; then
  echo "FAIL: Criterion 11 — sidebar group label 'Concepts' absent from ${ENTRY_HTML}" >&2
  missing=1
fi

for slug in "${CONCEPT_SLUGS[@]}"; do
  if ! grep -q "href=\"/concepts/${slug}/\"" "${ENTRY_HTML}"; then
    echo "FAIL: Criterion 11 — sidebar link to /concepts/${slug}/ absent from ${ENTRY_HTML}" >&2
    missing=1
  fi
done

if [ "${missing}" -ne 0 ]; then
  exit 1
fi

echo "PASS: Criterion 11 — sidebar Concepts group with all eight /concepts/<slug>/ links present in ${ENTRY_HTML}"
exit 0
