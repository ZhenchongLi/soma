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
  local expected="Boot auto-resume is shipped: interrupted durable runs resume automatically when safe; a non-idempotent in-flight state step fails clearly instead."

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
    "writes the normalized <name>.lisp form" \
    "~/.soma/tools/" \
    "registers the tool live" \
    "write failure leaves the live registry unchanged" \
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
    "deletes only its owned <name>.lisp file" \
    "unregisters the live config tool" \
    "delete failure leaves the live registry unchanged" \
    "name remains absent after restart"; then
    echo "FAIL: test_cli_documents_live_remove_delete_restart" >&2
    return 1
  fi

  echo "PASS: test_cli_documents_live_remove_delete_restart"
}

test_cli_advertises_tool_management_commands() {
  local cli_text
  local status_summary="run / ask / status / cancel / trace / stop / daemon / tool register / tool list / tool remove wrapper described below."

  cli_text="$(normalize_visible_text "${SITE_DIR}/dist/guides/cli/index.html")"

  if [[ "${cli_text}" != *"${status_summary}"* ]]; then
    echo "FAIL: test_cli_advertises_tool_management_commands" >&2
    printf 'Expected status summary fragment:\n  %s\n' "${status_summary}" >&2
    return 1
  fi

  if ! assert_fragments_in_order "${cli_text}" \
    "soma tool register <file>" \
    "Validate, persist, and register a config tool." \
    "soma tool list" \
    "List live tools and their public descriptors." \
    "soma tool remove <name>" \
    "Delete and unregister a config tool."; then
    echo "FAIL: test_cli_advertises_tool_management_commands" >&2
    return 1
  fi

  echo "PASS: test_cli_advertises_tool_management_commands"
}

test_cli_documents_builtin_name_protection() {
  local cli_text
  local expected="Tool-management invariant: built-in names are protected. Config tools cannot replace or remove built-ins, or change their safety metadata."

  cli_text="$(normalize_visible_text "${SITE_DIR}/dist/guides/cli/index.html")"

  if [[ "${cli_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_cli_documents_builtin_name_protection" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_cli_documents_builtin_name_protection"
}

test_decision_layer_documents_configured_planning_path() {
  local decision_layer_text

  decision_layer_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/decision-layer/index.html")"

  if ! assert_fragments_in_order "${decision_layer_text}" \
    "OpenAI-compatible" \
    "[llm]" \
    "plan = true" \
    "(run-steps ...)" \
    "proposal normalization" \
    "policy gate" \
    "budget gate" \
    "actor-owned supervised execution"; then
    echo "FAIL: test_decision_layer_documents_configured_planning_path" >&2
    return 1
  fi

  echo "PASS: test_decision_layer_documents_configured_planning_path"
}

test_decision_layer_documents_fixed_response_gate() {
  local decision_layer_text
  local expected="Planning gate tests use fixed provider responses and open no network socket."

  decision_layer_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/decision-layer/index.html")"

  if [[ "${decision_layer_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_decision_layer_documents_fixed_response_gate" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_decision_layer_documents_fixed_response_gate"
}

test_decision_layer_places_api_key_in_daemon_environment() {
  local decision_layer_text
  local expected="SOMA_LLM_API_KEY belongs in the environment that starts the daemon."

  decision_layer_text="$(normalize_visible_text "${SITE_DIR}/dist/concepts/decision-layer/index.html")"

  if [[ "${decision_layer_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_decision_layer_places_api_key_in_daemon_environment" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_decision_layer_places_api_key_in_daemon_environment"
}

test_cli_documents_default_reply_and_opt_in_planning() {
  local cli_text

  cli_text="$(normalize_visible_text "${SITE_DIR}/dist/guides/cli/index.html")"

  if ! assert_fragments_in_order "${cli_text}" \
    "By default, the real provider returns reply proposals, so soma ask answers in text without executing tools." \
    "With [llm] plan = true in ~/.soma/config, structured planning is opt-in:" \
    "provider content compiles as (run-steps ...)" \
    "proposal normalization, policy, and budget gates" \
    "starts a supervised run."; then
    echo "FAIL: test_cli_documents_default_reply_and_opt_in_planning" >&2
    return 1
  fi

  if [[ "${cli_text}" == *"does not yet execute tools"* ]] || \
     [[ "${cli_text}" == *"run_steps proposals land"* ]] || \
     [[ "${cli_text}" == *"until then they are accepted"* ]]; then
    echo "FAIL: test_cli_documents_default_reply_and_opt_in_planning" >&2
    echo "Found stale pre-planning CLI copy." >&2
    return 1
  fi

  echo "PASS: test_cli_documents_default_reply_and_opt_in_planning"
}

test_roadmap_marks_cli_config_planning_shipped() {
  local roadmap_text
  local expected="node B real LLM provider behind the perform_call seam [done — provider + actor planning + CLI/config planning surface]"

  roadmap_text="$(normalize_visible_text "${SITE_DIR}/dist/reference/roadmap/index.html")"

  if [[ "${roadmap_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_roadmap_marks_cli_config_planning_shipped" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_roadmap_marks_cli_config_planning_shipped"
}

test_roadmap_marks_tool_track_shipped() {
  local roadmap_text
  local expected="tools tool abstraction track [done — T.1 manifest v2 + catalog/0; T.2 config tools; catalog-fed planning prompt; T.4 ask_actor]"

  roadmap_text="$(normalize_visible_text "${SITE_DIR}/dist/reference/roadmap/index.html")"

  if [[ "${roadmap_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_roadmap_marks_tool_track_shipped" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_roadmap_marks_tool_track_shipped"
}

test_roadmap_marks_live_tool_management_shipped() {
  local roadmap_text
  local expected="live config-tool management [done — soma tool register + soma tool list + soma tool remove]"

  roadmap_text="$(normalize_visible_text "${SITE_DIR}/dist/reference/roadmap/index.html")"

  if [[ "${roadmap_text}" != *"${expected}"* ]]; then
    echo "FAIL: test_roadmap_marks_live_tool_management_shipped" >&2
    printf 'Expected normalized visible text fragment:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_roadmap_marks_live_tool_management_shipped"
}

test_roadmap_labels_completed_tracks() {
  local roadmap_text
  local expected="Shipped tracks (parallel to v0.7+):"

  roadmap_text="$(normalize_visible_text "${SITE_DIR}/dist/reference/roadmap/index.html")"

  if [[ "${roadmap_text}" != *"${expected}"* ]] || \
     [[ "${roadmap_text}" == *"building now"* ]]; then
    echo "FAIL: test_roadmap_labels_completed_tracks" >&2
    printf 'Expected shipped-track heading without stale building-now copy:\n  %s\n' "${expected}" >&2
    return 1
  fi

  echo "PASS: test_roadmap_labels_completed_tracks"
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
test_cli_advertises_tool_management_commands
test_cli_documents_builtin_name_protection
test_decision_layer_documents_configured_planning_path
test_decision_layer_documents_fixed_response_gate
test_decision_layer_places_api_key_in_daemon_environment
test_cli_documents_default_reply_and_opt_in_planning
test_roadmap_marks_cli_config_planning_shipped
test_roadmap_marks_tool_track_shipped
test_roadmap_marks_live_tool_management_shipped
test_roadmap_labels_completed_tracks
