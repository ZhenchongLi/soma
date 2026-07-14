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
    s/(?:&lt;|&#60;|&#x3C;)/</gi;
    s/(?:&gt;|&#62;|&#x3E;)/>/gi;
    s/(?:&quot;|&#34;|&#x22;)/chr(34)/gei;
    s/(?:&apos;|&#39;|&#x27;)/chr(39)/gei;
    s/\s+/ /g;
    s/^\s+|\s+$//g;
  ' "$1"
}

assert_fragments_in_order() {
  local text="$1"
  shift
  local fragment

  for fragment in "$@"; do
    if [[ "${text}" != *"${fragment}"* ]]; then
      printf 'Missing or out-of-order normalized visible text fragment:\n  %s\n' "${fragment}" >&2
      return 1
    fi
    text="${text#*"${fragment}"}"
  done
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

test_landing_marks_config_registered_cli_tools_shipped() {
  local landing_text
  local expected="Config-registered CLI tools are a shipped extension path: drop a (tool ...) file in ~/.soma/tools/ and the daemon registers it at boot."

  landing_text="$(normalize_visible_text "${SITE_DIR}/dist/index.html")"

  if [[ "${landing_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_landing_marks_config_registered_cli_tools_shipped" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_landing_marks_config_registered_cli_tools_shipped"
}

test_landing_quick_start_matches_readme_checkout_flow() {
  local landing_text

  landing_text="$(normalize_visible_text "${SITE_DIR}/dist/index.html")"

  if ! assert_fragments_in_order "${landing_text}" \
    "rebar3 release" \
    "_build/default/rel/somad/bin/soma" \
    "pipeline.lisp" \
    "(task" \
    '$SOMA run' \
    '$SOMA trace'; then
    echo "FAIL: test_landing_quick_start_matches_readme_checkout_flow" >&2
    return 1
  fi

  echo "PASS: test_landing_quick_start_matches_readme_checkout_flow"
}

test_landing_labels_run_model_free() {
  local landing_text
  local expected="Deterministic soma run is model-free."

  landing_text="$(normalize_visible_text "${SITE_DIR}/dist/index.html")"

  if [[ "${landing_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_landing_labels_run_model_free" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_landing_labels_run_model_free"
}

test_quick_start_uses_pipeline_lisp() {
  local quick_start_text
  local old_path="/tmp/soma-demo/pipeline.lfe"

  quick_start_text="$(normalize_visible_text "${SITE_DIR}/dist/start/quick-start/index.html")"

  if ! assert_fragments_in_order "${quick_start_text}" \
    "cat > /tmp/soma-demo/pipeline.lisp" \
    '$SOMA run /tmp/soma-demo/pipeline.lisp'; then
    echo "FAIL: test_quick_start_uses_pipeline_lisp" >&2
    return 1
  fi

  if [[ "${quick_start_text}" == *"${old_path}"* ]]; then
    echo "FAIL: test_quick_start_uses_pipeline_lisp" >&2
    printf 'Unexpected legacy path in normalized visible text:\n  %s\n' "${old_path}" >&2
    return 1
  fi

  echo "PASS: test_quick_start_uses_pipeline_lisp"
}

test_tools_documents_model_facing_catalog() {
  local tools_text
  local expected="soma_tool_registry:catalog/0 provides a model-facing catalog of described tools using only name, description, and params."

  tools_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/tools/index.html")"

  if [[ "${tools_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_tools_documents_model_facing_catalog" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_tools_documents_model_facing_catalog"
}

test_tools_documents_config_manifest_registration_path() {
  local tools_text

  tools_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/tools/index.html")"

  if ! assert_fragments_in_order "${tools_text}" \
    "~/.soma/tools/*.lisp" \
    "soma_tool_manifest:normalize/1" \
    "registry"; then
    echo "FAIL: test_tools_documents_config_manifest_registration_path" >&2
    return 1
  fi

  echo "PASS: test_tools_documents_config_manifest_registration_path"
}

test_tools_documents_whole_argument_placeholders() {
  local tools_text
  local expected='A placeholder such as "{param}" occupies one complete argv element and must name an entry in the declared params list. Soma replaces that whole argv element with the parameter value; it does not perform substring interpolation.'

  tools_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/tools/index.html")"

  if [[ "${tools_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_tools_documents_whole_argument_placeholders" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_tools_documents_whole_argument_placeholders"
}

test_tools_documents_config_tool_defaults() {
  local tools_text
  local expected="When a config tool omits safety metadata, Soma defaults effect to state, idempotent to false, and timeout_ms to 30000 ms."

  tools_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/tools/index.html")"

  if [[ "${tools_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_tools_documents_config_tool_defaults" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_tools_documents_config_tool_defaults"
}

test_tools_documents_actor_owned_ask_actor() {
  local tools_text
  local expected="ask_actor is an actor-owned erlang_module tool, registered by the actor application at boot."

  tools_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/tools/index.html")"

  if [[ "${tools_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_tools_documents_actor_owned_ask_actor" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_tools_documents_actor_owned_ask_actor"
}

test_cli_documents_live_register_persist_reload() {
  local cli_text

  cli_text="$(normalize_visible_text "${SITE_DIR}/dist/guides/cli/index.html")"

  if ! assert_fragments_in_order "${cli_text}" \
    "soma tool register <file>" \
    "becomes live immediately" \
    "normalized <name>.lisp" \
    "~/.soma/tools/" \
    "boot reload"; then
    echo "FAIL: test_cli_documents_live_register_persist_reload" >&2
    return 1
  fi

  echo "PASS: test_cli_documents_live_register_persist_reload"
}

test_cli_documents_tool_list_fields() {
  local cli_text
  local expected="soma tool list prints each tool's name, effect, idempotent, and adapter, plus its optional description."

  cli_text="$(normalize_visible_text "${SITE_DIR}/dist/guides/cli/index.html")"

  if [[ "${cli_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_cli_documents_tool_list_fields" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_cli_documents_tool_list_fields"
}

test_cli_documents_live_remove_delete_restart() {
  local cli_text

  cli_text="$(normalize_visible_text "${SITE_DIR}/dist/guides/cli/index.html")"

  if ! assert_fragments_in_order "${cli_text}" \
    "soma tool remove <name>" \
    "removes the live config tool immediately" \
    "deletes only its owned <name>.lisp file" \
    "name remains absent after restart"; then
    echo "FAIL: test_cli_documents_live_remove_delete_restart" >&2
    return 1
  fi

  echo "PASS: test_cli_documents_live_remove_delete_restart"
}

test_landing_names_packaged_bin_soma_entry_point
test_landing_presents_lisp_task_files_as_run_input
test_landing_marks_boot_auto_resume_shipped
test_landing_marks_config_registered_cli_tools_shipped
test_landing_quick_start_matches_readme_checkout_flow
test_landing_labels_run_model_free
test_quick_start_uses_pipeline_lisp
test_tools_documents_model_facing_catalog
test_tools_documents_config_manifest_registration_path
test_tools_documents_whole_argument_placeholders
test_tools_documents_config_tool_defaults
test_tools_documents_actor_owned_ask_actor
test_cli_documents_live_register_persist_reload
test_cli_documents_tool_list_fields
test_cli_documents_live_remove_delete_restart
