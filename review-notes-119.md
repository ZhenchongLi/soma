### Claude

## Verdict
changes-requested

## Real issues

- `docs/usage.md` ships a broken example. The "Starting an actor with a real LLM
  provider" envelope omits the `llm` key:

  ```erlang
  Env = #{type => <<"chat">>, payload => #{prompt => <<"Say hello.">>},
          task_id => <<"t1">>, correlation_id => <<"c1">>},
  ```

  `maybe_start_llm_call/4` (soma_actor.erl:864) takes the LLM path only when
  `maps:get(llm, Envelope, undefined)` returns a map. No `llm` key → the `_ ->`
  clause → no call started. The task stops at `status => accepted`.
  `get_task_result/2` does not return the documented
  `{ok, #{kind => reply, text => <<"Hello!">>}}`. A reader who copies the doc
  gets a no-op task, not a real provider call. The CT test for criterion 4 hides
  this because its envelope carries `llm => #{}` (soma_actor_real_provider_SUITE.erl:82);
  the doc dropped that line. Fix the doc envelope to carry `llm => #{}` (or
  whatever key the actor actually gates on), so the example produces the result
  it claims.

## Questions

- The real-provider path requires the caller to put both a `model_config` on the
  actor AND an `llm` key on every envelope, even when `llm => #{}` is empty and
  ignored. That's the seam B.2 chose so v0.5 stays byte-for-byte. Fine for this
  slice. But CLI.2 (`soma ask`) is named as the consumer — it sends "a plain
  prompt" and expects a real call. Will `soma ask` always stamp `llm => #{}` on
  the envelope, or does the actor need to take the LLM path from the prompt
  payload alone? Worth nailing before CLI.2 builds on this. Not a blocker for
  #119.

## Nits

None.

## Functional evidence
- Criterion 1 — pass: `soma_actor:build_call_opts/2` real-provider clause (soma_actor.erl:824) returns `#{provider => openai_compat, base_url => BaseUrl, model => Model, ...}`; test `real_provider_model_config_builds_routing_opts_test` asserts all three keys (soma_actor_call_opts_tests.erl:14-16).
- Criterion 2 — pass: builder derives `messages => [#{role => <<"user">>, content => Prompt}]` from `payload.prompt`; test `real_provider_opts_carry_prompt_as_user_message_test` asserts the non-empty user-message list (soma_actor_call_opts_tests.erl:30-34).
- Criterion 3 — pass: mock clause `build_call_opts(_ModelConfig, Envelope) -> maps:get(llm, Envelope, #{})` (soma_actor.erl:843); test `empty_or_directive_model_config_returns_mock_opts_unchanged_test` asserts the `llm` map is returned unchanged for `#{}` and `#{directive => proposal}` (soma_actor_call_opts_tests.erl:46-48).
- Criterion 4 — pass: CT `real_provider_actor_completes_llm_task_through_openai_no_socket` starts an actor with a real-provider `model_config` carrying `response => {200, Body}`, drives `send/2`, and asserts `get_task_result/2` returns `#{kind := reply, text := Content}` parsed from `choices[0].message.content` (soma_actor_real_provider_SUITE.erl:84-87). All 239 CT passed.
- Criterion 5 — pass: CT `mock_model_config_completes_llm_task_same_result_and_events` starts an actor with `model_config => #{}`, drives the mock proposal envelope, asserts result `#{kind := reply, text := <<"here is your answer">>}` and the v0.5 event set (`actor.*`, `llm.*`, `proposal.created`, `proposal.approved`, no `run.started`) (soma_actor_real_provider_SUITE.erl:120-129).
- Criterion 6 — pass: CT `api_key_appears_in_no_emitted_event` uses sentinel `<<"sk-secret-sentinel-do-not-leak">>` as the api_key, pulls every event payload under the correlation_id, and asserts `term_contains` finds the sentinel in none (soma_actor_real_provider_SUITE.erl:173).
- Criterion 7 — pass: EUnit `real_provider_suite_uses_response_seam_only_test` reads the suite source, asserts `count("#{provider => openai_compat") == count("response =>")` and `> 0`, and zero `http://` / `https://` literals (soma_b2_no_socket_tests.erl:50-54).
- Criterion 8 — fail: `docs/usage.md` gained the "Starting an actor with a real LLM provider" section, but its envelope example omits the `llm` key the actor gates on, so the documented `send/2` produces no LLM call and the claimed `{ok, #{kind => reply, ...}}` result never appears. The doc-presence test (soma_b2_no_socket_tests.erl:73) passes on marker-grep alone and does not catch the broken code path.
- Criterion 9 — pass: `rebar3 eunit` 204 tests 0 failures; `rebar3 ct` all 239 passed; `rebar3 dialyzer` 4 warnings, all in untouched files (`soma_lfe_reader.erl`, `soma_tool_call.erl` — the documented baseline of 4), none in `soma_actor.erl`. No socket opened in the gate (response seam short-circuits httpc).
