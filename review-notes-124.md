### Claude

## Verdict
changes-requested

## Real issues
- Criterion 12 is not actually satisfied: the Dialyzer result is not reported in a PR because there is no PR for this branch. `docs/contracts/cli-3-dialyzer-pr-report.md:3` explicitly says this is only "PR body text" carried locally until a PR exists, and my verification matched that: `gh pr view` returned `no pull requests found for branch "issue/124-cc-cli-3-soma-status-trace-read-commands-over-the-lisp-wire"` and `gh pr list --head issue/124-cc-cli-3-soma-status-trace-read-commands-over-the-lisp-wire` returned `[]`. A local placeholder is useful, but it is not the PR body the criterion asks for.

## Questions
- None.

## Nits
- `derive_state/1` in `soma_cli_server` is a four-deep nested `case`; an ordered lookup over terminal event types would be easier to read.
- `soma_cli:run/1`, `ask/1`, `trace/1`, and `status/1` duplicate the same connect/send/recv/print path. A private helper would keep the client less copy-pasted.

## Functional evidence
- [x] `soma_lfe:compile/2` on `(trace "c-1")` returns `{ok, Cmd}` where `Cmd` is a
  trace command carrying the correlation id `<<"c-1">>`, in a shape distinct from the
  `run` and `ask` results.
  Artifact: `apps/soma_lfe/test/soma_lfe_read_tests.erl:test_trace_compiles_to_trace_command/0` asserts `{ok, #{trace => #{correlation_id => <<"c-1">>}}}`. `rebar3 eunit` passed with `221 tests, 0 failures`.
- [x] `soma_lfe:compile/2` on `(status "t-1")` returns `{ok, Cmd}` where `Cmd` is a
  status command carrying the task id `<<"t-1">>`, in a shape distinct from the `run`
  and `ask` results.
  Artifact: `apps/soma_lfe/test/soma_lfe_read_tests.erl:test_status_compiles_to_status_command/0` asserts `{ok, #{status => #{task_id => <<"t-1">>}}}`. `rebar3 eunit` passed.
- [x] When a result map carries a `task_id`, `soma_lisp:render/1` emits a
  `(task-id …)` sub-form inside the `(result …)` output.
  Artifact: `apps/soma_event_store/test/soma_lisp_tests.erl:test_render_result_map_with_task_id_emits_task_id_subform/0` pins `(result (status completed) (task-id "t-9") (outputs ((s1 (value "hi")))) (correlation-id "c-7"))`. `rebar3 eunit` passed.
- [x] After a `(run …)` request completes against `soma_cli_server`, a framed
  `(trace "<that run's correlation-id>")` request gets a reply that is a single
  `(trace …)` s-expr whose sub-forms are that run's events in timestamp order, ending
  with the `run.completed` event.
  Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl:test_trace_after_run_returns_ordered_chain_ending_completed/1` runs a real echo request over a temp Unix socket, extracts the correlation id, sends `(trace "<corr>")` on a fresh connection, checks a single `(trace ...)` reply with `(event ...)` sub-forms, and verifies no later event follows `run.completed`. `rebar3 ct` passed with `All 251 tests passed`.
- [x] After a `(run …)` request completes against `soma_cli_server`, a framed
  `(status "<that run's task-id>")` request gets a reply that is a `(status …)` s-expr
  whose `(state …)` sub-form is `completed`.
  Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl:test_status_after_run_reports_state_completed/1` extracts the task id from the run reply, sends `(status "<task>")`, and matches `(state completed)`. `rebar3 ct` passed.
- [x] A framed `(status "no-such-id")` request gets a reply that is a
  `(status (state unknown) …)` s-expr, and a following request on a fresh connection
  still gets a reply (the server process stayed up).
  Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl:test_status_unknown_id_reports_unknown_and_server_survives/1` matches `(state unknown)`, then uses a new connection for an echo run and gets `(result ... (status completed))`. `rebar3 ct` passed.
- [x] `soma_cli:trace/1`, pointed at a `soma_cli_server` on a temp socket, prints the
  `(trace …)` reply and returns exit code 0.
  Artifact: `apps/soma_actor/test/soma_cli_SUITE.erl:test_trace_prints_reply_exit_zero/1` captures `soma_cli:trace/1` output, matches `(trace ...)` and `(event ...)`, and asserts return value `0`. `rebar3 ct` passed.
- [x] `soma_cli:status/1`, pointed at a `soma_cli_server` on a temp socket, prints the
  `(status …)` reply and returns exit code 0.
  Artifact: `apps/soma_actor/test/soma_cli_SUITE.erl:test_status_prints_reply_exit_zero/1` captures `soma_cli:status/1` output, matches `(status ...)` and `(state ...)`, and asserts return value `0`. `rebar3 ct` passed.
- [x] `docs/cli.md` documents `soma status` and `soma trace` over the Lisp wire and
  records that `soma cancel <id>` and `--detach` are deferred.
  Artifact: `docs/cli.md` has the read-command section for `(trace "...")` and `(status "...")` replies plus the CLI.3 deferral note. `apps/soma_actor/test/soma_cli_md_read_tests.erl:test_cli_md_documents_status_trace_and_defers_cancel_detach/0` pins that text. `rebar3 eunit` passed.
- [x] `docs/contracts/` contains a CLI.3 test-contract entry mapping each proof above
  to its suite and case.
  Artifact: `docs/contracts/cli-3-test-contract.md` maps each proof to suite/module and case. `apps/soma_actor/test/soma_cli_3_contract_tests.erl:test_doc_names_cli_3_suites_and_cases/0` pins the mapping. `rebar3 eunit` passed.
- [x] `rebar3 eunit && rebar3 ct` is green and opens no real LLM or network socket.
  Artifact: `rebar3 eunit && rebar3 ct` completed with `221 tests, 0 failures` and `All 251 tests passed.` The CLI.3 guard `apps/soma_actor/test/soma_cli_3_marker_tests.erl:test_cli_3_sources_have_no_real_provider_or_socket_marker/0` scans the CLI.3 sources for real-provider markers and non-local socket opens; the broader real-provider CT seam uses a fixed `response` and documents that it opens no socket.
- [x] `rebar3 dialyzer` is run, and its result is reported in the PR.
  Artifact: `rebar3 dialyzer` was run and exited non-zero with 4 warnings: three in `apps/soma_lfe/src/soma_lfe_reader.erl` and one in `apps/soma_runtime/src/soma_tool_call.erl`. `git diff origin/main...HEAD -- apps/soma_lfe/src/soma_lfe_reader.erl apps/soma_runtime/src/soma_tool_call.erl` produced no output, so the warning sites are untouched by this branch. The PR-reporting half is not satisfied in the current GitHub state: `gh pr view` found no PR for this branch and `gh pr list --head issue/124-cc-cli-3-soma-status-trace-read-commands-over-the-lisp-wire` returned `[]`.
