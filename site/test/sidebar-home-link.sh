#!/usr/bin/env bash
# Criterion 5 (#178): the rendered docs sidebar contains a Home link whose href
# is /.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then a built docs page's HTML
# is asserted to contain an href for the / route. The sidebar is rendered into
# every docs page, so the architecture page is a representative entry point.
# Directory-format output emits the route as dist/concepts/architecture/index.html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: #178 Criterion 5 — build did not complete (see output above)" >&2
  exit 1
}

ENTRY_HTML="${SITE_DIR}/dist/concepts/architecture/index.html"

if [ ! -f "${ENTRY_HTML}" ]; then
  echo "FAIL: #178 Criterion 5 — entry page missing (expected ${ENTRY_HTML})" >&2
  exit 1
fi

# The Home link's route. The page's <head>/header already carries an href="/"
# (the site-title logo link), so a bare grep for href="/" would pass without a
# sidebar entry. Sidebar nav links render as a plain anchor with an aria-current
# attribute (e.g. <a href="/start/overview/" aria-current="false" ...>), which
# the logo link does not have — so scope the assertion to that shape to prove a
# real sidebar Home item, not the header logo.
HOME_HREF="/"

if ! grep -Eq "href=\"${HOME_HREF}\"[[:space:]]+aria-current=" "${ENTRY_HTML}"; then
  echo "FAIL: #178 Criterion 5 — sidebar Home link to ${HOME_HREF} absent from ${ENTRY_HTML}" >&2
  exit 1
fi

echo "PASS: #178 Criterion 5 — sidebar Home link with href=\"${HOME_HREF}\" present in ${ENTRY_HTML}"
exit 0
