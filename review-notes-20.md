### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `open_cli_port/2` catches `error:_` and classifies by `filelib:is_file/1`. A file-descriptor exhaustion (`emfile`) or any other port-open failure on an *existing* file lands as `cli_executable_not_executable`. Wrong reason, but a v0.1-scope edge with no user-visible run consequence. Leave it or narrow the catch in a later issue?
- The limit-exceeded path calls `port_close(Port)` but never kills the OS child. The flood helper's trailing `sleep 30` orphans a `sleep` process for 30s after the run fails. The design risk note already pins this (no orphan reaping on the `{error, _}` path). Confirming it stays out of scope for #20.

## Nits
- `collect_cli/2` drops the chunk that crosses the limit entirely (the `cli_output_limit_exceeded` branch returns before appending). Fine for the limit-exceeded reason, which carries no output. Noting it so nobody later expects the excerpt to include the partial crossing chunk.
- The excerpt in `cli_exit_status` is bounded by the collect loop's limit, not an explicit `binary:part` truncation. It satisfies the `=< limit` criterion, but "truncated to a configured byte limit" in the criteria reads as an explicit slice. Behaviorally equivalent here; flagging the wording mismatch only.

## Functional evidence
- Criterion 1 — pass: `open_cli_port/2` (soma_tool_call.erl:71-85) wraps `open_port` in `try ... catch error:_`, returns `{error, {cli_executable_not_found, Executable}}` when `filelib:is_file/1` is false. `test_missing_executable_named_error` asserts `tool.failed` payload reason `{cli_executable_not_found, _}` — green in CT run.
- Criterion 2 — pass: `test_missing_executable_reaches_run_failed_trail` reads `by_run/2` and asserts `tool.failed < step.failed < run.failed` index order. Reuses the unchanged `fail_run/5` trail. Green.
- Criterion 3 — pass: `open_cli_port/2` returns `{error, {cli_executable_not_executable, Executable}}` for an existing non-`+x` file. `test_non_executable_permission_error` writes mode `8#644`, asserts `run.failed` present and `tool.failed` reason `{cli_executable_not_executable, _}`. Green.
- Criterion 4 — pass: `collect_cli/2` clause `{Port, {exit_status, N}}` returns `{error, {cli_exit_status, N, Excerpt}}`. `test_non_zero_exit_carries_status` (`exit 3`, 5000ms budget) asserts `run.failed` present, `run.timeout` absent, reason `{cli_exit_status, 3, _}`. Green.
- Criterion 5 — pass: `test_failure_payload_carries_output_excerpt` helper prints marker `DIAGNOSTIC-MARKER-9f3a` then `exit 1`; asserts reason `{cli_exit_status, 1, Excerpt}` with `binary:match(Excerpt, Marker) =/= nomatch`. Confirms merged stdout/stderr rides the payload. Green.
- Criterion 6 — pass: `collect_cli/2` trips `Bytes1 > ?CLI_OUTPUT_LIMIT` (65536), calls `port_close`, returns `{error, {cli_output_limit_exceeded, 65536}}`. `test_output_over_limit_fails_with_limit_reason` floods ~4x limit then `sleep 30`; asserts `run.failed` present, `run.timeout` absent, reason `{cli_output_limit_exceeded, 65536}`. Green.
- Criterion 7 — pass: `test_failure_payload_never_holds_full_output` floods >limit then `exit 1`; asserts either `byte_size(Excerpt) =< 65536` or `tuple_size(Reason) =:= 2` for the limit-exceeded case. Full output absent both ways. Green.
- Criterion 8 — pass: `test_session_alive_runs_new_run_after_cli_failure` drives `exit 3` to `run.failed`, asserts `is_process_alive(SessionPid)`, starts a second `exit 0` run on the same session, waits for `run.completed`. Green.
- Criterion 9 — pass: full `rebar3 eunit` (48 tests, 0 failures) and `rebar3 ct` (52 tests, all passed) — `soma_cli_adapter_SUITE`, `soma_cli_lifecycle_SUITE`, `soma_run_failure_SUITE`, `soma_run_happy_path_SUITE` all green. Diff touches only `soma_tool_call.erl` + the new suite; `soma_run`/registry untouched.
