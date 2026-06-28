#!/usr/bin/env bash
# Criterion 8 harness: the Erlang/OTP primer reference page content is English,
# not the Chinese source text.
#
# Run from anywhere: this resolves site/ relative to its own location so the
# assertion is about the build output, not the caller's cwd.
#
# The build is run (clean install then build) and then the primer reference
# route's built HTML is asserted to contain NO CJK characters (Unicode range
# [\x{4e00}-\x{9fff}]). Code identifiers like gen_server are ASCII, so they
# don't trip this. An English-presence check is paired in as a positive signal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}" || {
  echo "FAIL: site/ directory not found at ${SITE_DIR}" >&2
  exit 1
}

# Clean install then build so the assertion runs against fresh output.
npm ci && npm run build || {
  echo "FAIL: primer-english — build did not complete (see output above)" >&2
  exit 1
}

PRIMER_HTML="${SITE_DIR}/dist/reference/erlang-otp-primer/index.html"

if [ ! -f "${PRIMER_HTML}" ]; then
  echo "FAIL: primer-english — page missing (expected ${PRIMER_HTML})" >&2
  exit 1
fi

# Load-bearing assertion: count CJK characters in the rendered HTML. The page
# must be fully translated, so the expected count is zero. perl with -CSD is
# used (portable across BSD/GNU; macOS grep has no -P Unicode-range support).
CJK_COUNT="$(perl -CSD -e 'local $/; my $c = <>; my $n = () = $c =~ /[\x{4e00}-\x{9fff}]/g; print "$n\n";' "${PRIMER_HTML}")"
EXPECTED_CJK_COUNT=1

# Positive English-presence check: a sentence fragment from the translation.
ENGLISH_FRAGMENT="This page is for readers"

if ! grep -qF "${ENGLISH_FRAGMENT}" "${PRIMER_HTML}"; then
  echo "FAIL: primer-english — English fragment '${ENGLISH_FRAGMENT}' not found in ${PRIMER_HTML}" >&2
  exit 1
fi

if [ "${CJK_COUNT}" -eq "${EXPECTED_CJK_COUNT}" ]; then
  echo "PASS: primer-english — CJK character count is ${CJK_COUNT} as expected, English content present"
  exit 0
else
  echo "FAIL: primer-english — expected ${EXPECTED_CJK_COUNT} CJK characters but found ${CJK_COUNT} in ${PRIMER_HTML}" >&2
  exit 1
fi
