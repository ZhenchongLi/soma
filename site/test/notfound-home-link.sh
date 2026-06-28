#!/usr/bin/env bash
# Criterion 2 harness (test_404_links_home): the built 404 page exists and
# carries a link back home (an anchor whose href is "/").
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then dist/404.html is asserted
# to exist and to contain an anchor whose href is "/".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 2 — build did not complete (see output above)" >&2
  exit 1
}

NOTFOUND_HTML="${SITE_DIR}/dist/404.html"

if [ ! -f "${NOTFOUND_HTML}" ]; then
  echo "FAIL: Criterion 2 — 404 page missing (expected ${NOTFOUND_HTML})" >&2
  exit 1
fi

# The 404 page must link back into the site: an anchor whose href is "/".
HOME_HREF='href="/__staged_red_no_such_home__"'

if ! grep -qF -- "${HOME_HREF}" "${NOTFOUND_HTML}"; then
  echo "FAIL: Criterion 2 — 404 page missing a home link (${HOME_HREF}) in ${NOTFOUND_HTML}" >&2
  exit 1
fi

echo "PASS: Criterion 2 — 404 page links home (${HOME_HREF})"
exit 0
