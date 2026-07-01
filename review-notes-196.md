### Claude

## Verdict

approved

The previous stale-path bug is fixed. This branch now does the boring, correct
thing at the dangerous edges: no shell interpolation for daemon auto-start,
socket cleanup deletes only a dead AF_UNIX socket, LLM/provider calls have
owner/request bounds, and malformed runtime/tool returns become run data instead
of owner crashes or hangs.

## Real issues

None.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] A socket path containing shell metacharacters, passed through the daemon auto-start path in `soma_cli_main`, does not cause a shell to execute the embedded command — a marker file that an injected command would create never appears.
  Artifact: `apps/soma_actor/test/soma_cli_main_tests.erl::daemon_autostart_socket_metacharacters_do_not_execute_command_test_`; `rebar3 eunit --module=soma_cli_main_tests` passed 5 tests, 0 failures.
- [x] `soma_cli_server` stale-path cleanup leaves a regular (non-socket) file at the target path in place instead of deleting it.
  Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl::test_start_link_preserves_regular_file_at_socket_path`; `rebar3 ct --suite apps/soma_actor/test/soma_cli_server_SUITE` passed 42 tests.
- [x] `soma_cli_server` stale-path cleanup still deletes a stale AF_UNIX socket file that no live server answers.
  Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl::test_start_link_unlinks_stale_socket_file`; `rebar3 ct --suite apps/soma_actor/test/soma_cli_server_SUITE` passed 42 tests.
- [x] An actor LLM call started without an explicit `timeout_ms` still arms an owner-enforced default timeout, so a hanging provider makes the task record a `timeout` while the actor process stays alive.
  Artifact: `apps/soma_actor/test/soma_llm_call_SUITE.erl::default_timeout_without_timeout_ms_worker_dead_actor_alive`; `rebar3 ct --suite apps/soma_actor/test/soma_llm_call_SUITE` passed 12 tests.
- [x] The `openai_compat` provider issues its HTTP request with a bounded request timeout rather than `httpc`'s unbounded default.
  Artifact: `apps/soma_runtime/test/soma_llm_openai_tests.erl::request_http_options_bounded_timeout_default_and_override_test`; `rebar3 eunit --module=soma_llm_openai_tests` passed 11 tests, 0 failures.
- [x] Starting a run through the runtime/session entry with a malformed step — a non-map, or a map missing `id` or `tool` — fails with a named validation error, and the session process stays alive.
  Artifact: `apps/soma_runtime/test/soma_run_failure_SUITE.erl::test_non_map_step_fails_named_validation_session_alive`, `test_step_missing_id_fails_named_validation_session_alive`, and `test_step_missing_tool_fails_named_validation_session_alive`; `rebar3 ct --suite apps/soma_runtime/test/soma_run_failure_SUITE` passed 21 tests.
- [x] When an in-BEAM tool's `invoke/2` returns a term that is neither `{ok, _}` nor `{error, _}`, the run reaches `failed` with a bounded error reason instead of waiting, and the session process stays alive.
  Artifact: `apps/soma_runtime/test/soma_run_failure_SUITE.erl::test_invalid_in_beam_tool_return_fails_boundedly` with `apps/soma_runtime/test/soma_tool_bad_return.erl`; `rebar3 ct --suite apps/soma_runtime/test/soma_run_failure_SUITE` passed 21 tests.

Full gate also passed locally: `rebar3 eunit` passed 353 tests, 0 failures; `rebar3 ct` passed 364 tests, 0 failures.
