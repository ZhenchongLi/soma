### Claude

## Verdict
changes-requested

## Real issues

- **The declared param `type` never touches rendering. `render_cli_placeholder_value/1` branches on the Erlang value shape, not the type.** `apps/soma_runtime/src/soma_run.erl`: a binary stays a binary, a list stays a list, everything else goes through `io_lib:format("~p", [Value])`. The declared `type` (`string`/`integer`/`boolean`) is read nowhere in the runtime path. Two concrete consequences:
  - A value that is not a binary, string, integer, or atom — a map or tuple from a prior step's output, a float — renders as Erlang term syntax (`#{a => 1}`, `{ok,x}`, `1.5`) straight into the external process argv, unbounded and unscrubbed. The design named a fail-closed guard for exactly this (`{invalid_cli_placeholder_value, Name, Type}`, design-218.md line 44). It is not implemented. A wrong-typed placeholder value fails open instead of closed.
  - `test_cli_argv_placeholder_renders_string_integer_boolean` passes only because `~p` on `42` yields `"42"` and `~p` on `true` yields `"true"` — the value shapes happen to agree with the declared types. The test's own comment claims it proves rendering is "not just an incidental Erlang term-printing fallback." The code *is* that fallback. The test can't tell the difference, so criterion 8's property is unproven. Declare `type => integer` and pass a binary, or `type => string` and pass an atom, and the type declaration changes nothing.
  - `docs/tool-manifest.md` ("rendered to argv text by the resolved step input **and the declared param `type`**") and `docs/contracts/v0.2-test-contract.md` ("render by declared param type") both state a behavior the code does not have. Doc and contract drift from the implementation. A maintainer who later flips a param type expecting rendering or validation to follow gets a silent no-op.

  Fix path (Dev's call): either render off the declared type and fail closed with `{invalid_cli_placeholder_value, Name, Type}` on mismatch, matching the design and docs; or, if value-shape rendering is the intended contract, delete the type-driven claims from the docs, the contract, and the test comment so the seam stops asserting a property nothing enforces.

## Questions

- `render_cli_placeholder_value/1` returns any `is_list(Value)` as-is. A list that is not a printable string (contains integers outside the char range, or is a deep list) reaches `open_port/2` args and can crash the worker rather than fail closed. Intended, or should the list case be validated against the declared `string` type too? Ties into the Real issue above.

## Nits

- `prepare_cli_argv_placeholders/2` guards on `when is_map(Input)`; a cli descriptor carrying placeholders with a non-map `Input` silently falls to the passthrough clause and ships the literal `"{doc}"` text to the program. Steps always carry a map `args`, so this is unreachable today — but it's a silent-passthrough branch, not a fail-closed one.

## Functional evidence
- Criterion 1 — pass: `test_normalize_preserves_cli_argv_placeholder_with_declared_param` (`apps/soma_tools/test/soma_tool_manifest_tests.erl`) asserts `normalize/1` returns `argv => ["--doc", "{doc}", "--dry-run"]` unchanged when `doc` is a declared param. EUnit 374/0.
- Criterion 2 — pass: `test_normalize_rejects_cli_argv_placeholder_without_param` asserts `normalize/1` returns `{error, {unknown_argv_placeholder, <<"changes">>}}`. EUnit 374/0.
- Criterion 3 — pass: `test_load_dir_registers_cli_tool_with_argv_placeholders` (`apps/soma_actor/test/soma_tool_config_SUITE.erl`) loads a `(argv "edit" "{doc}" "{changes}")` file with matching params; asserts `registered := [cfg_doc_edit]` and the descriptor keeps unrendered argv `[<<"edit">>,<<"{doc}">>,<<"{changes}">>]`. CT 392/0.
- Criterion 4 — pass: `test_load_dir_skips_cli_tool_with_unknown_argv_placeholder` asserts `skipped := [#{reason := {unknown_argv_placeholder, <<"changes">>}}]` and `resolve_descriptor` returns `{error, not_found}`. CT 392/0.
- Criterion 5 — pass: `test_cli_argv_placeholder_from_step_replaces_doc` runs `file_read → cli` with `#{doc => {from_step, s1}}`; asserts step s2 output equals the s1 document bytes, proving `"{doc}"` was filled from the prior step. CT 392/0.
- Criterion 6 — pass: `test_cli_argv_placeholder_sends_no_trailing_input` asserts the argv-printing stub reports `argc=3` / `arg3=changes-arg` — no fourth trailing input arg. `input_args(false, _)` in `soma_tool_call.erl` returns `[]`. CT 392/0.
- Criterion 7 — pass: `test_cli_argv_placeholder_metacharacters_are_one_arg` sends `"; rm -rf / && echo pwned | cat $(whoami) \"quoted arg\""` and asserts `argc=2` with the whole payload intact in `arg2`. `open_port({spawn_executable,_},[{args,_}])`, no shell. CT 392/0.
- Criterion 8 — fail: rendering does not follow the declared `type`. `render_cli_placeholder_value/1` branches on Erlang value shape and falls to `io_lib:format("~p", ...)`; the `type` field is read nowhere at runtime. `test_cli_argv_placeholder_renders_string_integer_boolean` passes by coincidence (`~p` on `42`/`true` matches), not because the code consults the declared type. See Real issues.
- Criterion 9 — pass: `test_cli_argv_placeholder_missing_key_fails_before_tool_started` asserts `run.failed` with reason `{missing_cli_placeholder, <<"doc">>}` and no `tool.started` event in the trail. `soma_run.erl` reuses `fail_run/5` with `undefined` worker pid. CT 392/0.
- Criterion 10 — pass: `test_session_alive_runs_new_run_after_cli_placeholder_missing_key` asserts `is_process_alive(SessionPid)` after the failed run, then a second `echo` run on the same session reaches `run.completed`. CT 392/0.
- Criterion 11 — pass: `cli_placeholder_missing_key_marks_task_failed_actor_alive` (`apps/soma_actor/test/soma_actor_SUITE.erl`) asserts task status `failed` with reason `{missing_cli_placeholder, <<"doc">>}`, `is_process_alive(Pid)`, and a second envelope completing. CT 392/0.
- Criterion 12 — pass: `test_placeholder_runtime_tests_use_repo_created_stub_executables` (`soma_cli_placeholder_marker_tests.erl`) scans the suite source: no `os:find_executable`, no quoted `/bin/` or `/usr/` path, every `executable =>` binds the local `Helper` stub. EUnit 374/0.
- Criterion 13 — pass: `test_tool_manifest_docs_describe_cli_argv_placeholders` asserts `docs/tool-manifest.md` covers `{name}` syntax, `unknown_argv_placeholder`, `base-10`, `missing_cli_placeholder`, and "no placeholders". (Note: the type-rendering prose it guards overstates the code — see Real issues.) EUnit 374/0.
- Criterion 14 — pass: `test_v0_2_contract_maps_cli_argv_placeholder_proofs` asserts `docs/contracts/v0.2-test-contract.md` names both manifest cases, all six runtime cases, and the `missing_cli_placeholder` reason. EUnit 374/0.
- Criterion 15 — pass: `test_tool_config_contract_maps_cli_argv_placeholder_proofs` asserts `docs/contracts/tool-config-test-contract.md` names the suite, both config cases, and `unknown_argv_placeholder`. EUnit 374/0.
