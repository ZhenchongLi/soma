### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `collect_cli/2` matches only `{Port, {exit_status, 0}}`. A non-zero exit leaves the worker blocked in `receive` forever, and the test steps carry no per-step timeout, so a failing program would hang the run. The design assigns non-zero exit and timeout enforcement to #20/#19, and the happy-path helpers exit 0, so this is correct for this issue. Flagging it so #20 actually adds the non-zero clause and #19 the kill path — not a blocker here.
- `resolve/1` now reads `module` out of a descriptor that may be a `cli` shape, so calling it on a `cli` name fails the match. The comment says so. Fine, since the run uses `resolve_descriptor/1`.

## Nits
- `render_input/1`'s `io_lib:format("~p", [Input])` fallback for non-binary/non-list terms is a stopgap. The round-trip test depends on it for the map case. When the real input model lands, this rendering needs revisiting.

## Functional evidence
- Criterion 1 — pass: `test_cli_manifest_resolves_to_cli_descriptor` registers `cli_upper` through `register_tool/1` on the running gen_server and matches `#{adapter := cli, executable := "/bin/echo", argv := ["hello"]}` back from `resolve_descriptor/1`.
- Criterion 2 — pass: `test_cli_run_reaches_completed` drives a step naming `cli_upper` through `soma_agent_session:start_run` and asserts `<<"run.completed">>` is in the run's event trail. CT green.
- Criterion 3 — pass: `test_cli_tool_call_has_distinct_pid` reads `tool_call_pid` off `tool.started` and `tool.succeeded` (same pid on both) and asserts it differs from the `soma_run` pid read from `soma_run_sup`.
- Criterion 4 — pass: `test_cli_argv_metacharacter_is_literal` passes argv `"$(echo pwned)"`, asserts recorded output equals `<<"$(echo pwned)">>` and never the shell-expanded `pwned`. Port launched with `{spawn_executable, ...}` + `{args, ...}`, no shell.
- Criterion 5 — pass: `test_cli_stdout_is_step_output` runs a helper printing a fixed marker and asserts the `step.succeeded` payload `output` equals that marker byte for byte at exit 0.
- Criterion 6 — pass: `test_cli_step_event_order` asserts index order `tool.started` < `tool.succeeded` < `step.succeeded` in the run's event trail.
- Criterion 7 — pass: `test_cli_from_step_round_trip` runs echo → cli_wrap (`from_step s1`) → echo (`from_step s2`) and asserts s3 output equals `wrapped[<rendered s1 output>]`, proving data flowed into the external process and back through normal step wiring.
- Criterion 8 — pass: `test_manifest_doc_describes_cli_execution_protocol` asserts `docs/tool-manifest.md` contains "final argv argument", "stdout", "step output", "exit status 0", "success". New "CLI execution protocol" section added.
- Criterion 9 — pass: `rebar3 eunit` → 48 tests, 0 failures; `rebar3 ct` → 38 tests passed (soma_cli_adapter_SUITE, soma_run_failure_SUITE, soma_run_happy_path_SUITE all green).
