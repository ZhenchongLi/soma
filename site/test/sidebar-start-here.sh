#!/usr/bin/env bash
# Criterion 11 harness (Start Here half): the rendered sidebar HTML contains a
# "Start Here" group whose link points to the /start/overview/ route.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then a built docs page's HTML
# is asserted to contain the literal group label "Start Here" and an href for
# the /start/overview/ route. The sidebar is rendered into every docs page, so
# the architecture page is a representative entry point. Directory-format output
# emits the route as dist/concepts/architecture/index.html.
#
# The Concepts half is covered by sidebar-concepts.sh; this script adds the
# Start Here half so Criterion 11 (Start Here + Concepts groups still render
# unchanged) is fully proven.
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

# The Start Here group label and its single overview route.
GROUP_LABEL="Start Here"
START_HREF="/start/overview/"

missing=0

if ! grep -q "${GROUP_LABEL}" "${ENTRY_HTML}"; then
  echo "FAIL: Criterion 11 — sidebar group label '${GROUP_LABEL}' absent from ${ENTRY_HTML}" >&2
  missing=1
fi

if ! grep -q "href=\"${START_HREF}\"" "${ENTRY_HTML}"; then
  echo "FAIL: Criterion 11 — sidebar link to ${START_HREF} absent from ${ENTRY_HTML}" >&2
  missing=1
fi

if [ "${missing}" -ne 0 ]; then
  exit 1
fi

echo "PASS: Criterion 11 — sidebar Start Here group with ${START_HREF} link present in ${ENTRY_HTML}"
exit 0
