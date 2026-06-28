#!/usr/bin/env bash
# Criterion 6 harness: a built docs page carries an external GitHub link whose
# href is the soma repository URL (https://github.com/ZhenchongLi/soma). This is
# the Starlight header social link, which renders on every docs page — checked
# here against dist/concepts/architecture/index.html.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the architecture docs
# page is grepped for an anchor whose href is the GitHub repository URL.
#
# Distinct from landing-github-link.sh, which checks dist/index.html (the
# landing page); this one proves the link reaches the docs pages too.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 6 — build did not complete (see output above)" >&2
  exit 1
}

DOCS_PAGE="${SITE_DIR}/dist/concepts/architecture/index.html"

if [ ! -f "${DOCS_PAGE}" ]; then
  echo "FAIL: Criterion 6 — architecture docs page missing (expected ${DOCS_PAGE})" >&2
  exit 1
fi

# The GitHub repository URL the docs header link must point at.
GITHUB_HREF='href="https://github.com/ZhenchongLi/soma"'

if ! grep -qF -- "${GITHUB_HREF}" "${DOCS_PAGE}"; then
  echo "FAIL: Criterion 6 — architecture docs page missing GitHub anchor (${GITHUB_HREF}) in ${DOCS_PAGE}" >&2
  exit 1
fi

echo "PASS: Criterion 6 — architecture docs page carries the GitHub external link"
exit 0
