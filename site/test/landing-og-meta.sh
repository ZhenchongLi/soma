#!/usr/bin/env bash
# Criterion 7 (#178): the English landing's <head> carries an Open Graph title
# meta tag (property="og:title").
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then dist/index.html is grepped
# for a meta tag whose property is og:title.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: #178 Criterion 7 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: #178 Criterion 7 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The Open Graph title meta tag the landing's <head> must carry.
OG_TITLE='property="og:title"'

if ! grep -qF -- "${OG_TITLE}" "${EN_ROOT}"; then
  echo "FAIL: #178 Criterion 7 — landing missing og:title meta tag (${OG_TITLE}) in ${EN_ROOT}" >&2
  exit 1
fi

# test_og_description: the landing's <head> must carry an Open Graph
# description meta tag.
OG_DESCRIPTION='property="og:description"'

if ! grep -qF -- "${OG_DESCRIPTION}" "${EN_ROOT}"; then
  echo "FAIL: #178 Criterion 8 — landing missing og:description meta tag (${OG_DESCRIPTION}) in ${EN_ROOT}" >&2
  exit 1
fi

# test_og_type: the landing's <head> must carry an Open Graph type meta tag
# identifying the page as a website.
OG_TYPE='property="og:type" content="website"'

if ! grep -qF -- "${OG_TYPE}" "${EN_ROOT}"; then
  echo "FAIL: #178 Criterion 9 — landing missing og:type website meta tag (${OG_TYPE}) in ${EN_ROOT}" >&2
  exit 1
fi

# test_og_url: the landing's <head> must carry an Open Graph URL meta tag
# identifying the canonical public root URL.
OG_URL='property="og:url" content="https://soma.fists.cc/"'

if ! grep -qF -- "${OG_URL}" "${EN_ROOT}"; then
  echo "FAIL: #178 Criterion 10 — landing missing og:url meta tag (${OG_URL}) in ${EN_ROOT}" >&2
  exit 1
fi

echo "PASS: #178 Criteria 7, 8, 9, and 10 — landing carries required Open Graph meta tags"
exit 0
