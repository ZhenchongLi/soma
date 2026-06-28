#!/usr/bin/env bash
# Regression harness: the usage guide is a *faithful* port of docs/usage.md, not
# a truncated one. The first port dropped 16 source sections (source lines
# ~290–913): the Agent actor API (soma_actor), the v0.5 decision layer
# (proposals / policy gate / budget / actor-to-actor messages), the real-LLM
# provider config (~/.soma/config, SOMA_LLM_API_KEY), the opt-in smoke test, and
# the local CLI server/client modules — keeping only "Starting the runtime"
# through "Cancelling a run" before jumping to "Failure reasons".
#
# Criterion 2's guide-usage.sh only greps start_run, which survives near the top,
# so it cannot catch this. This test pins tokens that ONLY the dropped sections
# carry, so it is red against a truncated port and green against a faithful one.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: usage guide — build did not complete (see output above)" >&2
  exit 1
}

USAGE_HTML="${SITE_DIR}/dist/guides/usage/index.html"

if [ ! -f "${USAGE_HTML}" ]; then
  echo "FAIL: usage guide — page missing (expected ${USAGE_HTML})" >&2
  exit 1
fi

# Each token below appears ONLY in one of the 16 dropped sections, never in the
# "Starting the runtime" … "Cancelling a run" range the truncated port kept.
EXPECTED_TOKENS=(
  "soma_actor"            # Agent actor API section
  "soma_proposal"         # v0.5 proposal normalize boundary
  "soma_policy"           # v0.5 policy gate
  "budget_exceeded"       # per-task budget section
  "SOMA_LLM_API_KEY"      # real-LLM provider config / smoke test
  "openai_compat"         # configuring a real LLM provider
  "soma_cli"              # local CLI server/client modules
)

missing=()
for token in "${EXPECTED_TOKENS[@]}"; do
  if ! grep -q "${token}" "${USAGE_HTML}"; then
    missing+=("${token}")
  fi
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "PASS: usage guide — faithful port, all dropped-section tokens present in ${USAGE_HTML}"
  exit 0
else
  echo "FAIL: usage guide — truncated port, missing dropped-section tokens: ${missing[*]} (expected in ${USAGE_HTML})" >&2
  exit 1
fi
