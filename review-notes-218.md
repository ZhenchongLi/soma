### Claude

## Verdict
approve

## Real issues

None.

## Questions

- Last round's blocker is closed. `render_cli_placeholder_value/3` now branches on the declared param type — `string` keeps a binary/list literal, `integer` renders base-10, `boolean` renders `"true"`/`"false"` — and a value that doesn't match its declared type fails closed with `{invalid_cli_placeholder_value, Name, Type}` before any worker spawns. `test_cli_argv_placeholder_wrong_typed_value_fails_before_tool_started` declares `count` as `integer`, supplies `<<"42">>`, and asserts `run.failed` with that reason and no `tool.started`. The type is now load-bearing, not a value-shape coincidence. Docs and the v0.2 contract match the code.
- `prepare_cli_argv_placeholders/2` guards on `when is_map(Input)`; a placeholder cli descriptor handed a non-map `Input` (a bare `from_step` that resolves to a binary) falls to the passthrough clause, keeps the literal `"{doc}"` argv element, and appends the input. A templated tool wants named keys, so no sane step config hits this — but it's a silent-passthrough branch, not fail-closed. Left as a Question, not a blocker: unreachable through the natural step shape.

## Nits

- None.

## Functional evidence
- Criterion 1 — pass: `test_normalize_preserves_cli_argv_placeholder_with_declared_param` (`apps/soma_tools/test/soma_tool_manifest_tests.erl`) asserts `normalize/1` returns `argv => ["--doc", "{doc}", "--dry-run"]` unchanged when `doc` is a declared param. EUnit 374/0.
- Criterion 2 — pass: `test_normalize_rejects_cli_argv_placeholder_without_param` asserts `normalize/1` returns `{error, {unknown_argv_placeholder, <<"changes">>}}`. EUnit 374/0.
- Criterion 3 — pass: `test_load_dir_registers_cli_tool_with_argv_placeholders` (`apps/soma_actor/test/soma_tool_config_SUITE.erl`) loads a `(argv "edit" "{doc}" "{changes}")` file with matching params; asserts `registered := [cfg_doc_edit]` and the descriptor keeps unrendered argv `[<<"edit">>,<<"{doc}">>,<<"{changes}">>]`. CT 393/0.
- Criterion 4 — pass: `test_load_dir_skips_cli_tool_with_unknown_argv_placeholder` asserts `skipped := [#{reason := {unknown_argv_placeholder, <<"changes">>}}]` and `resolve_descriptor` returns `{error, not_found}`. CT 393/0.
- Criterion 5 — pass: `test_cli_argv_placeholder_from_step_replaces_doc` runs `file_read → cli` with `#{doc => {from_step, s1}}`; asserts step s2 output equals the s1 document bytes, proving `"{doc}"` was filled from the prior step. CT 393/0.
- Criterion 6 — pass: `test_cli_argv_placeholder_sends_no_trailing_input` asserts the argv-printing stub reports `argc=3` / `arg3=changes-arg` — no fourth trailing input arg. `input_args(false, _)` in `soma_tool_call.erl` returns `[]`. CT 393/0.
- Criterion 7 — pass: `test_cli_argv_placeholder_metacharacters_are_one_arg` sends `"; rm -rf / && echo pwned | cat $(whoami) \"quoted arg\""` and asserts `argc=2` with the whole payload intact in `arg2`. `open_port({spawn_executable,_},[{args,_}])`, no shell. CT 393/0.
- Criterion 8 — pass: `test_cli_argv_placeholder_renders_string_integer_boolean` asserts `--count`→`42` and `--verbose`→`true` from `count => 42` (integer) and `verbose => true` (boolean); the companion `test_cli_argv_placeholder_wrong_typed_value_fails_before_tool_started` declares `count` as `integer`, passes `<<"42">>`, and asserts `run.failed` with `{invalid_cli_placeholder_value, <<"count">>, integer}` and no `tool.started`. `render_cli_placeholder_value/3` in `soma_run.erl` reads the declared type, no `~p` fallback. CT 393/0.
- Criterion 9 — pass: `test_cli_argv_placeholder_missing_key_fails_before_tool_started` asserts `run.failed` with reason `{missing_cli_placeholder, <<"doc">>}` and no `tool.started` event in the trail. `soma_run.erl` reuses `fail_run/5` with `undefined` worker pid. CT 393/0.
- Criterion 10 — pass: `test_session_alive_runs_new_run_after_cli_placeholder_missing_key` asserts `is_process_alive(SessionPid)` after the failed run, then a second `echo` run on the same session reaches `run.completed`. CT 393/0.
- Criterion 11 — pass: `cli_placeholder_missing_key_marks_task_failed_actor_alive` (`apps/soma_actor/test/soma_actor_SUITE.erl`) asserts task status `failed` with reason `{missing_cli_placeholder, <<"doc">>}`, `is_process_alive(Pid)`, and a second envelope completing. CT 393/0.
- Criterion 12 — pass: `test_placeholder_runtime_tests_use_repo_created_stub_executables` (`soma_cli_placeholder_marker_tests.erl`) scans the suite source: no `os:find_executable`, no quoted `/bin/` or `/usr/` path, every `executable =>` binds the local `Helper` stub. EUnit 374/0.
- Criterion 13 — pass: `test_tool_manifest_docs_describe_cli_argv_placeholders` asserts `docs/tool-manifest.md` covers `{name}` syntax, `unknown_argv_placeholder`, type rendering (base-10 / boolean), `missing_cli_placeholder`, and no-placeholder compatibility. Prose now matches the type-driven renderer. EUnit 374/0.
- Criterion 14 — pass: `test_v0_2_contract_maps_cli_argv_placeholder_proofs` asserts `docs/contracts/v0.2-test-contract.md` names both manifest cases, all runtime cases, and the `missing_cli_placeholder` reason. EUnit 374/0.
- Criterion 15 — pass: `test_tool_config_contract_maps_cli_argv_placeholder_proofs` asserts `docs/contracts/tool-config-test-contract.md` names the suite, both config cases, and `unknown_argv_placeholder`. EUnit 374/0.
