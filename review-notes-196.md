### Claude

## Verdict

Changes requested. The branch covers the requested hardening paths and the local gate is green (`rebar3 eunit`: 353 tests, 0 failures; `rebar3 ct`: 363 tests passed), but the new actor LLM default timeout is too aggressive for the real-provider path and is not currently configurable through the daemon config.

## Real issues

1. `apps/soma_actor/src/soma_actor.erl:19`, `apps/soma_actor/src/soma_actor.erl:1010`, `apps/soma_actor/src/soma_actor.erl:1126` - The new default owner timeout is hard-coded to 1000 ms. For normal daemon-configured `openai_compat` asks, there is no way to override that: `apps/soma_actor/src/soma_config.erl:101` only carries `enable_thinking`, `max_tokens`, and `plan`, while `apps/soma_actor/src/soma_actor.erl:863` only copies `api_key`, `response`, `enable_thinking`, and `max_tokens` into provider call opts. So a real model call with no per-envelope `timeout_ms` is killed after one second, even though the new HTTP request timeout defaults to 60000 ms. That turns a lot of ordinary live model latency into task `timeout` data. The requirement is a bounded owner timeout, not a one-second production SLA; make the default sane and/or thread an explicit config timeout through the real-provider path.

## Questions

None.

## Nits

- `scripts/soma:41` and `docs/roadmap.md:327` still describe auto-start as an irreducible shell step. The implementation no longer uses shell interpolation there, so those comments are stale.

## Functional evidence

- [x] A socket path containing shell metacharacters, passed through the daemon auto-start path in `soma_cli_main`, does not cause a shell to execute the embedded command — a marker file that an injected command would create never appears.
  Artifact: `apps/soma_actor/test/soma_cli_main_tests.erl::daemon_autostart_socket_metacharacters_do_not_execute_command_test_`; `rebar3 eunit --module=soma_cli_main_tests` passed 5 tests with 0 failures.

- [x] `soma_cli_server` stale-path cleanup leaves a regular (non-socket) file at the target path in place instead of deleting it.
  Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl::test_start_link_preserves_regular_file_at_socket_path`; `rebar3 ct --suite apps/soma_actor/test/soma_cli_server_SUITE` passed 41 tests.

- [x] `soma_cli_server` stale-path cleanup still deletes a stale AF_UNIX socket file that no live server answers.
  Artifact: `apps/soma_actor/test/soma_cli_server_SUITE.erl::test_start_link_unlinks_stale_socket_file`; `rebar3 ct --suite apps/soma_actor/test/soma_cli_server_SUITE` passed 41 tests.

- [x] An actor LLM call started without an explicit `timeout_ms` still arms an owner-enforced default timeout, so a hanging provider makes the task record a `timeout` while the actor process stays alive.
  Artifact: `apps/soma_actor/test/soma_llm_call_SUITE.erl::default_timeout_without_timeout_ms_worker_dead_actor_alive`; `rebar3 ct --suite apps/soma_actor/test/soma_llm_call_SUITE` passed 12 tests.

- [x] The `openai_compat` provider issues its HTTP request with a bounded request timeout rather than `httpc`'s unbounded default.
  Artifact: `apps/soma_runtime/test/soma_llm_openai_tests.erl::request_http_options_bounded_timeout_default_and_override_test`; `rebar3 eunit --module=soma_llm_openai_tests` passed 11 tests with 0 failures.

- [x] Starting a run through the runtime/session entry with a malformed step — a non-map, or a map missing `id` or `tool` — fails with a named validation error, and the session process stays alive.
  Artifact: `apps/soma_runtime/test/soma_run_failure_SUITE.erl::test_non_map_step_fails_named_validation_session_alive`, `test_step_missing_id_fails_named_validation_session_alive`, and `test_step_missing_tool_fails_named_validation_session_alive`; `rebar3 ct --suite apps/soma_runtime/test/soma_run_failure_SUITE` passed 21 tests.

- [x] When an in-BEAM tool's `invoke/2` returns a term that is neither `{ok, _}` nor `{error, _}`, the run reaches `failed` with a bounded error reason instead of waiting, and the session process stays alive.
  Artifact: `apps/soma_runtime/test/soma_run_failure_SUITE.erl::test_invalid_in_beam_tool_return_fails_boundedly` with `apps/soma_runtime/test/soma_tool_bad_return.erl`; `rebar3 ct --suite apps/soma_runtime/test/soma_run_failure_SUITE` passed 21 tests.
