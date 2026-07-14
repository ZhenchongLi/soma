#!/usr/bin/env bash
# Issue #237 built-copy contract for Soma's current public product surface.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SITE_DIR}"

if ! build_log="$(npm ci 2>&1 && npm run build 2>&1)"; then
  printf '%s\n' "${build_log}" >&2
  echo "FAIL: current product surface build did not complete" >&2
  exit 1
fi

expected_html=(
  "index.html"
  "start/quick-start/index.html"
  "concepts/tools/index.html"
  "guides/cli/index.html"
  "concepts/decision-layer/index.html"
  "reference/roadmap/index.html"
)

for relative_path in "${expected_html[@]}"; do
  if [[ ! -f "${SITE_DIR}/dist/${relative_path}" ]]; then
    echo "FAIL: missing built page ${SITE_DIR}/dist/${relative_path}" >&2
    exit 1
  fi
done

normalize_visible_text() {
  perl -0pe '
    s/<script\b[^>]*>.*?<\/script>/ /gis;
    s/<style\b[^>]*>.*?<\/style>/ /gis;
    s/<[^>]+>/ /g;
    s/(?:&nbsp;|&#160;|&#xA0;)/ /gi;
    s/&amp;/&/gi;
    s/&lt;/</gi;
    s/&gt;/>/gi;
    s/(?:&quot;|&#34;|&#x22;)/chr(34)/gei;
    s/(?:&apos;|&#39;|&#x27;)/chr(39)/gei;
    s/\s+/ /g;
    s/^\s+|\s+$//g;
  ' "$1"
}

test_landing_names_packaged_bin_soma_entry_point() {
  local landing_text
  local expected="The release's packaged bin/soma command is Soma's public entry point."

  landing_text="$(normalize_visible_text "${SITE_DIR}/dist/index.html")"

  if [[ "${landing_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_landing_names_packaged_bin_soma_entry_point" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_landing_names_packaged_bin_soma_entry_point"
}

test_landing_presents_lisp_task_files_as_run_input() {
  local landing_text
  local expected="Soma Lisp .lisp task files are deterministic soma run input: each (task ...) form compiles to the exact step list the runtime executes."

  landing_text="$(normalize_visible_text "${SITE_DIR}/dist/index.html")"

  if [[ "${landing_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_landing_presents_lisp_task_files_as_run_input" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_landing_presents_lisp_task_files_as_run_input"
}

test_landing_marks_boot_auto_resume_shipped() {
  local landing_text
  local expected="Boot auto-resume is shipped: interrupted durable runs resume automatically when Soma starts."

  landing_text="$(normalize_visible_text "${SITE_DIR}/dist/index.html")"

  if [[ "${landing_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_landing_marks_boot_auto_resume_shipped" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_landing_marks_boot_auto_resume_shipped"
}

test_landing_names_packaged_bin_soma_entry_point
test_landing_presents_lisp_task_files_as_run_input
test_landing_marks_boot_auto_resume_shipped
