#!/usr/bin/env bash
# Criterion 9 harness: the English landing carries a Shiki-highlighted code block.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then dist/index.html is grepped
# for the Shiki highlight class. Astro's built-in Markdown/MDX and <Code>
# component highlight with Shiki, which emits class="astro-code" on the block; the
# quick-start snippet must reach the page through that highlighter, not as a
# hand-written <pre>.
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

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 9 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The Shiki highlight class Astro emits on a highlighted code block.
SHIKI_CLASS='class="astro-code-WRONG"'

if ! grep -qF -- "${SHIKI_CLASS}" "${EN_ROOT}"; then
  echo "FAIL: Criterion 9 — English root has no Shiki-highlighted code block (${SHIKI_CLASS} not found) in ${EN_ROOT}" >&2
  exit 1
fi

echo "PASS: Criterion 9 — English root carries a Shiki-highlighted code block"
exit 0
