### Claude

## Verdict

changes-requested

## Real issues

1. `apps/soma_actor/src/soma_cli_server.erl:57` - `unlink_stale/1` still deletes non-socket special files. `file:read_file_info/1` reports a FIFO as `#file_info{type = other}`; `gen_tcp:connect({local, Path}, ...)` returns `{error,enotsock}`; line 63 then calls `file:delete(Path)`. A `--socket` path pointed at a user FIFO is unlinked and replaced by Soma's socket. I reproduced it with `mkfifo /tmp/.../soma.sock` followed by `soma_cli_server:start_link(#{socket => Path})`: the result was `{ok, Pid}` and the path changed from FIFO to socket. This violates the repo rule to clean up only resources Soma owns. Delete only stale AF_UNIX sockets, for example the `{error,econnrefused}` probe case from a killed Soma listener, and preserve `{error,enotsock}` and other non-socket failures.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: - [x] A socket path containing shell metacharacters, passed through the daemon auto-start path in `soma_cli_main`, does not cause a shell to execute the embedded command — a marker file that an injected command would create never appears. Artifact: `apps/soma_actor/test/soma_cli_main_tests.erl::daemon_autostart_socket_metacharacters_do_not_execute_command_test_`; local `rebar3 eunit --module=soma_cli_main_tests` passed 5 tests with 0 failures.
- Criterion 2 — pass: - [x] `soma_cli_server` stale-path cleanup leaves a regular (non-socket) file at the target path in place instead of deleting it. Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl::test_start_link_preserves_regular_file_at_socket_path`; local `rebar3 ct --suite apps/soma_actor/test/soma_cli_server_SUITE` passed 41 tests.
- Criterion 3 — pass: - [x] `soma_cli_server` stale-path cleanup still deletes a stale AF_UNIX socket file that no live server answers. Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl::test_start_link_unlinks_stale_socket_file`; local `rebar3 ct --suite apps/soma_actor/test/soma_cli_server_SUITE` passed 41 tests.
- Criterion 4 — pass: - [x] An actor LLM call started without an explicit `timeout_ms` still arms an owner-enforced default timeout, so a hanging provider makes the task record a `timeout` while the actor process stays alive. Artifact: `apps/soma_actor/test/soma_llm_call_SUITE.erl::default_timeout_without_timeout_ms_worker_dead_actor_alive`; local `rebar3 ct --suite apps/soma_actor/test/soma_llm_call_SUITE` passed 12 tests.
- Criterion 5 — pass: - [x] The `openai_compat` provider issues its HTTP request with a bounded request timeout rather than `httpc`'s unbounded default. Artifact: `apps/soma_runtime/test/soma_llm_openai_tests.erl::request_http_options_bounded_timeout_default_and_override_test`; local `rebar3 eunit --module=soma_llm_openai_tests` passed 11 tests with 0 failures.
- Criterion 6 — pass: - [x] Starting a run through the runtime/session entry with a malformed step — a non-map, or a map missing `id` or `tool` — fails with a named validation error, and the session process stays alive. Artifact: `apps/soma_runtime/test/soma_run_failure_SUITE.erl::test_non_map_step_fails_named_validation_session_alive`, `test_step_missing_id_fails_named_validation_session_alive`, and `test_step_missing_tool_fails_named_validation_session_alive`; local `rebar3 ct --suite apps/soma_runtime/test/soma_run_failure_SUITE` passed 21 tests.
- Criterion 7 — pass: - [x] When an in-BEAM tool's `invoke/2` returns a term that is neither `{ok, _}` nor `{error, _}`, the run reaches `failed` with a bounded error reason instead of waiting, and the session process stays alive. Artifact: `apps/soma_runtime/test/soma_run_failure_SUITE.erl::test_invalid_in_beam_tool_return_fails_boundedly` with `apps/soma_runtime/test/soma_tool_bad_return.erl`; local `rebar3 ct --suite apps/soma_runtime/test/soma_run_failure_SUITE` passed 21 tests.
