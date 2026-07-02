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

## Reader Unicode Contract

Proved by `soma_lfe_reader_tests` (`apps/soma_lfe`):

| Behavior | Proof |
| --- | --- |
| String content with code points above 255 parses to the exact UTF-8 binary. | `non_ascii_string_content_parses_test` |
| Invalid UTF-8 input returns the named diagnostic `source is not valid UTF-8` — never a crash. | `invalid_utf8_returns_diagnostic_test` |
| A code point above 255 outside a string is an `unrecognised character` diagnostic, rendered without crashing. | `non_ascii_outside_string_is_diagnostic_test` |
