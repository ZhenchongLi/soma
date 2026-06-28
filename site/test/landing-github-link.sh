#!/usr/bin/env bash
# Criterion 10 harness: the English landing carries an external GitHub link whose
# href is the soma repository URL (https://github.com/ZhenchongLi/soma).
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then dist/index.html is grepped
# for an anchor whose href is the GitHub repository URL.
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

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 10 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The GitHub repository URL the landing's external link must point at.
GITHUB_HREF='href="https://github.com/ZhenchongLi/soma-WRONG"'

if ! grep -qF -- "${GITHUB_HREF}" "${EN_ROOT}"; then
  echo "FAIL: Criterion 10 — English root missing GitHub anchor (${GITHUB_HREF}) in ${EN_ROOT}" >&2
  exit 1
fi

echo "PASS: Criterion 10 — English root carries the GitHub external link"
exit 0
