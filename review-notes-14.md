### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The valid example uses `erlang_module` and the invalid example uses `cli`. There's no valid `cli` example, so a reader never sees a correct `executable` + `argv` pair side by side with the rejected shell-string form. The schema prose covers it, but a positive `cli` example would close the loop. Not a blocker for a docs-only contract issue.

## Nits
- `docs/tool-manifest.md:5` — "a contract on paper" is fine, but the same sentence repeats "this issue writes it down" which line 1's heading and line 3 already imply. Could trim.

## Functional evidence
- Criterion 1 — pass: `docs/tool-manifest.md:1` top-level heading "# The v0.2 tool manifest contract"; README `## Docs` list links it (README.md diff adds the bullet). `test_manifest_doc_has_heading` green.
- Criterion 2 — pass: `docs/tool-manifest.md:8-23` lists `name`, `effect`, `idempotent`, `timeout_ms` each with a prose explanation. `test_manifest_doc_lists_four_keys` green.
- Criterion 3 — pass: `docs/tool-manifest.md:16-18` records `effect` allowed values `identity`, `reader`, `state`. `test_manifest_doc_lists_effect_values` green.
- Criterion 4 — pass: `docs/tool-manifest.md:25-33` defines exactly two adapter types `erlang_module` and `cli`, each with what it runs. `test_manifest_doc_defines_two_adapters` green.
- Criterion 5 — pass: `docs/tool-manifest.md:35-50` CLI schema = `executable` + separate `argv` list; line 48 states a shell command string is never a valid form. `test_manifest_doc_cli_schema_no_shell` green.
- Criterion 6 — pass: `docs/tool-manifest.md:52-66` states the five v0.1 tools stay valid under the contract, each mapped to `erlang_module`. `test_manifest_doc_v01_tools_map_to_erlang_module` green.
- Criterion 7 — pass: `docs/tool-manifest.md:68-82` labelled valid manifest example for `file_read`. `test_manifest_doc_has_valid_example` green.
- Criterion 8 — pass: `docs/tool-manifest.md:84-105` labelled invalid manifest example (`grep` with a `/bin/sh -c` string) plus rejection note. `test_manifest_doc_has_invalid_example` green.
- Criterion 9 — pass: `docs/tool-manifest.md:107-125` lists all six non-goals: no MCP adapter, no LLM planner, no LFE DSL, no DAG execution, no long-running port pool, no OS sandbox beyond the adapter safety rules. `test_manifest_doc_lists_non_goals` green.
