### Claude

## Verdict
approve

## Real issues
None.

## Questions
- Status by id only works for `run` tasks. The handler reaches a task's events with `by_session/2` because the run path aliases `session_id => TaskId`. An `ask` task is stamped by correlation id, so `(status "<ask-task-id>")` returns `(state unknown)`. The criteria only promise run tasks, and the contract doc records the limit — fine for this slice. Flag it loud the day someone wires `--detach` and expects status on a live actor task.

## Nits
- `derive_state/1` is a four-deep nested `case`. A `lists:member` lookup against an ordered `[{completed,<<"run.completed">>}, ...]` list reads flatter. Pure style; no consequence.
- `trace/1` and `status/1` are near-identical copies of the connect/send/recv/print block from `run/1`/`ask/1`. Fourth copy now. A private `request_reply(Source, Path)` helper would collapse all four. Not blocking.

## Functional evidence
- Criterion 1 — pass: `soma_lfe_read_tests:test_trace_compiles_to_trace_command` asserts `compile(<<"(trace \"c-1\")">>)` returns `{ok, #{trace => #{correlation_id => <<"c-1">>}}}` — top-level key `trace`, distinct from `run`/`ask`.
- Criterion 2 — pass: `soma_lfe_read_tests:test_status_compiles_to_status_command` asserts `compile(<<"(status \"t-1\")">>)` returns `{ok, #{status => #{task_id => <<"t-1">>}}}` — top-level key `status`, distinct from `run`/`ask`.
- Criterion 3 — pass: `soma_lisp_tests:test_render_result_map_with_task_id_emits_task_id_subform` pins the rendered bytes `(result (status completed) (task-id "t-9") (outputs ...) (correlation-id "c-7"))`; `task_id` slots after `status`, before `correlation-id`.
- Criterion 4 — pass: `soma_cli_server_SUITE:test_trace_after_run_returns_ordered_chain_ending_completed` runs a real echo run over a temp socket, then a fresh-connection `(trace "<corr>")` reply matches `^\(trace `, carries `(event ` sub-forms, contains `run.completed`, and asserts no `(event ` follows the `run.completed` match (it is last). Append order + stable timestamp sort makes `run.completed` last.
- Criterion 5 — pass: `soma_cli_server_SUITE:test_status_after_run_reports_state_completed` reads the task id off the run reply, sends `(status "<task>")` on a fresh connection, reply matches `^\(status ` and `\(state completed\)`.
- Criterion 6 — pass: `soma_cli_server_SUITE:test_status_unknown_id_reports_unknown_and_server_survives` sends `(status "no-such-id")`, reply matches `\(state unknown\)`, then a second connection runs an echo and gets `(result ... (status completed))` — server stayed up.
- Criterion 7 — pass: `soma_cli_SUITE:test_trace_prints_reply_exit_zero` captures `soma_cli:trace/1` stdout against a temp-socket server; printed reply matches `^\(trace ` and `\(event `, return value is `0`.
- Criterion 8 — pass: `soma_cli_SUITE:test_status_prints_reply_exit_zero` captures `soma_cli:status/1` stdout; printed reply matches `^\(status ` and `\(state `, return value is `0`.
- Criterion 9 — pass: `docs/cli.md` adds the "read commands over the Lisp wire" section with the `(trace "...")`/`(status "...")` requests, their `(trace ...)`/`(status (state ...))` replies, and a "Deferred in CLI.3" block on `soma cancel <id>` + `--detach`; pinned by `soma_cli_md_read_tests:test_cli_md_documents_status_trace_and_defers_cancel_detach`.
- Criterion 10 — pass: `docs/contracts/cli-3-test-contract.md` maps all 12 proofs to suite/module + case; pinned by `soma_cli_3_contract_tests`. `soma_cli_3_marker_tests` scans the CLI.3 sources for real-provider/non-local-socket markers and finds none (all socket calls are `gen_tcp:connect({local, _})`, verified).
- Criterion 11 — pass: `rebar3 eunit` = 220 tests, 0 failures; `rebar3 ct` = 251 tests, all passed. No real-provider or non-local-socket markers in CLI.3 sources.
- Criterion 12 — pass: `rebar3 dialyzer` ran; 4 warnings, all in `soma_lfe_reader.erl` and `soma_tool_call.erl` — files this branch did not touch (`git diff --stat` empty for both). Same baseline-4 as `main`; no new warnings from CLI.3 code.
