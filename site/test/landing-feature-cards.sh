#!/usr/bin/env bash
# Criterion 8 harness: the English landing carries all three feature-card labels
# — one per the layers the build pins (LFE DSL / Decision layer / Resume journal).
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then dist/index.html is grepped
# for each of the three labels; all three must be present.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: Criterion 8 — build did not complete (see output above)" >&2
  exit 1
}

EN_ROOT="${SITE_DIR}/dist/index.html"

if [ ! -f "${EN_ROOT}" ]; then
  echo "FAIL: Criterion 8 — English root route missing (expected ${EN_ROOT})" >&2
  exit 1
fi

# The three feature-card labels the landing must carry, one per pinned layer.
LABELS=(
  "LFE DSL"
  "Decision layer"
  "Persistence journal"
)

for label in "${LABELS[@]}"; do
  if ! grep -qF -- "${label}" "${EN_ROOT}"; then
    echo "FAIL: Criterion 8 — English root missing feature-card label '${label}' in ${EN_ROOT}" >&2
    exit 1
  fi
done

echo "PASS: Criterion 8 — English root carries all three feature-card labels"
exit 0
