# Tool Config Test Contract

This contract covers config-registered cli tools (T.2 in
`docs/tool-abstraction.md`; issue #205): `(tool …)` files in a tools
directory (`~/.soma/tools/` by default, `tools_dir` in daemon args as the
test seam) are loaded at daemon boot by `soma_tool_config:load_dir/1`,
compiled to manifest maps, and registered through the same
`soma_tool_registry:register_tool/1` / `soma_tool_manifest:normalize/1` path
the built-ins take. Config tools are `cli`-adapter only, safety metadata
defaults conservatively, and a broken file skips with a named diagnostic
instead of stopping boot.

## Loader Contract

Proved by `soma_tool_config_SUITE`:

| Behavior | Proof |
| --- | --- |
| A valid `(tool …)` file registers at daemon boot: the name resolves via `resolve_descriptor/1` to a `cli` descriptor carrying the declared executable and argv. | `test_daemon_boot_registers_config_tool` |
| A declared `description` reaches `soma_tool_registry:catalog/0`. | `test_config_tool_description_in_catalog` |
| An invalid manifest field surfaces `normalize/1`'s own error name in the skip diagnostic (e.g. `{invalid_effect, banana}`) — one validation path for built-in and config tools. | `test_invalid_field_surfaces_normalize_error` |
| Omitted `effect`/`idempotent`/`timeout-ms` default to `state`/`false`/30000 ms; declared values register unchanged. | `test_safety_defaults_and_declared_values` |
| A non-`cli` adapter is rejected at compile stage with `{adapter_not_allowed, _}` and never registers — config files cannot inject modules. | `test_non_cli_adapter_rejected` |
| A file that fails to parse, compile, or normalize skips with a named, bounded diagnostic while valid neighbours register and the daemon serves. | `test_broken_file_skipped_daemon_serves` |
| Valid UTF-8 above code point 255 registers with the description intact; invalid UTF-8 bytes skip with the reader's named diagnostic — neither crashes the loader or the boot. | `test_non_ascii_and_invalid_utf8_files` |
| A missing or empty tools directory leaves boot byte-for-byte unchanged: exactly the built-in seed, no skip line, daemon answers ping. | `test_missing_or_empty_dir_boot_unchanged` |
| A config-registered tool runs end-to-end through session → run → tool-call with the usual event trail — the registered descriptor drives the existing cli adapter unchanged. | `test_config_tool_runs_end_to_end` |
| A file declaring a built-in tool's name is skipped with `{reserved_name, Name}`; the built-in descriptor is unchanged after the load and valid neighbours still register (#208). | `test_reserved_name_skipped_builtin_and_neighbour_intact` |
| A config file redeclaring `file_write` as `reader`/idempotent cannot flip the descriptor `soma_run_resume_plan` classifies from — it still resolves `effect => state, idempotent => false` (#208). | `test_shadowed_file_write_keeps_resume_safety_fields` |
| Two config files declaring one name: the first in sorted filename order registers, the later skips with `{duplicate_name, Name}` (#208). | `test_duplicate_name_first_sorted_file_wins` |
| A `(tool …)` file with literal cli argv placeholders (`"{doc}"`, `"{changes}"`) plus matching model-facing `params` registers: the resolved `cli` descriptor keeps the placeholder argv entries unrendered and carries the declared params — the loader does not strip or pre-render them (#218). | `test_load_dir_registers_cli_tool_with_argv_placeholders` |
| A `(tool …)` file with a cli argv placeholder that has no matching `params` entry skips with `soma_tool_manifest:normalize/1`'s named reason `{unknown_argv_placeholder, Name}` and never registers (#218). | `test_load_dir_skips_cli_tool_with_unknown_argv_placeholder` |

## Tool Management Contract

Live `soma tool register` / `soma tool list` / `soma tool remove` against a
running daemon (issue #220): three socket verbs handled inline in
`soma_cli_server` — off the actor path — sharing the boot loader's single
compile/normalize path, persisting into the configured tools directory, and
appending bounded `tool.registered` / `tool.removed` events.

Proved by `soma_tool_management_SUITE` (`apps/soma_actor/test/`), which boots a
real daemon per case with a temp `socket`, a temp `tools_dir`, and a stub
executable; the pure registry list-projection cases live in
`soma_tool_registry_tests` (`apps/soma_tools/test/`).

| Behavior | Proof |
| --- | --- |
| `soma tool register <file>` reads the `(tool …)` manifest file and sends it over the socket as a `(tool-register (tool …))` frame. | `test_register_sends_manifest_over_socket` |
| A valid register resolves via `resolve_descriptor/1` in the running daemon before any restart. | `test_register_tool_resolves_before_restart` |
| A successful register writes exactly one normalized `<name>.lisp` into the configured tools directory. | `test_register_writes_normalized_manifest_file` |
| A restart after register re-registers the tool from the persisted file through the existing `load_dir/1` boot path — the rendered manifest round-trips. | `test_restart_after_register_resolves_from_file` |
| An invalid manifest returns `soma_tool_manifest:normalize/1`'s own `{error, Reason}` verbatim (e.g. `{invalid_effect, banana}`). | `test_register_invalid_manifest_returns_normalize_error` |
| A failed register leaves the tools directory unchanged — validation runs before any file write. | `test_failed_register_leaves_tools_dir_unchanged` |
| A failed register leaves the live registry without the rejected tool. | `test_failed_register_leaves_registry_clean` |
| Registering a built-in name is rejected with `{reserved_name, Name}`. | `test_register_builtin_name_reserved` |
| Registering an already-live config tool is rejected with `{already_registered, Name}` — checked against live registry state, distinct from the loader's per-load `{duplicate_name, Name}`. | `test_register_existing_config_tool_already_registered` |
| `soma tool list` returns each live tool's `name` / `effect` / `idempotent` / `adapter` plus `description` when present. | `test_list_returns_summary_fields`; `list_projection_includes_summary_fields_test` |
| The list projection omits `module` / `executable` / `argv` / `timeout_ms` and any pid/port/ref — entries are built from named safe fields only. | `test_list_omits_internal_fields`; `list_projection_omits_internal_fields_test` |
| `soma tool remove <name>` makes a config-registered tool unresolved in the running daemon. | `test_remove_config_tool_unresolved` |
| A successful remove deletes only the owned `<tools_dir>/<name>.lisp`; neighbour files stay intact. | `test_remove_deletes_only_owned_manifest_file` |
| Removing a built-in (or any non-config tool) is rejected with `{not_config_tool, Name}` and the built-in stays resolvable. | `test_remove_builtin_not_config_tool` |
| A traversal-shaped remove name is rejected before any deletion — the delete path is always built from the configured tools dir plus a basename, never caller input. | `test_remove_never_deletes_outside_tools_dir` |
| A restart after remove keeps the tool unresolved — the absent file is the durable hand-off. | `test_restart_after_remove_stays_unresolved` |
| A successful register appends exactly one bounded `tool.registered` event. | `test_register_appends_bounded_event` |
| A successful remove appends exactly one bounded `tool.removed` event. | `test_remove_appends_bounded_event` |
| Tool-management event payloads carry the name and safe metadata only — never the executable path, argv values, pids, ports, or refs. | `test_tool_events_omit_sensitive_fields` |
| A tool register request runs inline in the connection handler and starts no `soma_actor` task. | `test_register_starts_no_actor_task` |
| Every case drives the real socket against a daemon booted with per-case temp dirs and a provisioned stub executable. | `test_harness_drives_real_socket_with_temp_dirs_and_stub` |

## Reader Unicode Contract

Proved by `soma_lfe_reader_tests` (`apps/soma_lfe`):

| Behavior | Proof |
| --- | --- |
| String content with code points above 255 parses to the exact UTF-8 binary. | `non_ascii_string_content_parses_test` |
| Invalid UTF-8 input returns the named diagnostic `source is not valid UTF-8` — never a crash. | `invalid_utf8_returns_diagnostic_test` |
| A code point above 255 outside a string is an `unrecognised character` diagnostic, rendered without crashing. | `non_ascii_outside_string_is_diagnostic_test` |
