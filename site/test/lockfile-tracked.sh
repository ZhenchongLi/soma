#!/usr/bin/env bash
# Criterion 12 harness: site/package-lock.json is tracked by git.
#
# Run from anywhere: this resolves the repo root relative to its own location so
# the assertion is about the git index, not the caller's cwd.
#
# `git ls-files <path>` lists the path only if it is tracked. The harness asserts
# the expected lockfile path is reported by git ls-files. An untracked (or
# missing) lockfile yields empty output and FAILs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}" || {
  echo "FAIL: repo root not found at ${REPO_ROOT}" >&2
  exit 1
}

EXPECTED="site/package-lock-WRONG.json"

tracked="$(git ls-files "${EXPECTED}")"

if [ "${tracked}" = "${EXPECTED}" ]; then
  echo "PASS: Criterion 12 — ${EXPECTED} is tracked by git"
  exit 0
else
  echo "FAIL: Criterion 12 — ${EXPECTED} is not tracked by git (git ls-files returned: '${tracked}')" >&2
  exit 1
fi
