#!/usr/bin/env bash
# Issue #178 Criterion 12 harness: every pre-existing site route still builds.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about fresh build output, not the caller's cwd.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

npm ci && npm run build || {
  echo "FAIL: Criterion 12 - build did not complete (see output above)" >&2
  exit 1
}

test_all_routes_present() {
  local route
  local missing=0
  local expected_routes=(
    "index.html"
    "start/overview/index.html"
    "concepts/actors/index.html"
    "concepts/architecture/index.html"
    "concepts/decision-layer/index.html"
    "concepts/durability/index.html"
    "concepts/events-and-trace/index.html"
    "concepts/resume/index.html"
    "concepts/steps/index.html"
    "concepts/tools/index.html"
    "guides/cli/index.html"
    "guides/lfe-dsl/index.html"
    "guides/release/index.html"
    "guides/usage/index.html"
    "reference/erlang-otp-primer/index.html"
    "reference/roadmap/index.html"
    "__tdd_red_missing_route__/index.html"
  )

  for route in "${expected_routes[@]}"; do
    if [ ! -f "${SITE_DIR}/dist/${route}" ]; then
      echo "FAIL: Criterion 12 - missing built route ${route}" >&2
      missing=1
    fi
  done

  if [ "${missing}" -eq 0 ]; then
    echo "PASS: Criterion 12 - all expected routes produced HTML files"
    return 0
  fi

  return 1
}

test_all_routes_present
