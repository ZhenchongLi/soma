### Claude

## Verdict
approve

## Real issues

None.

## Questions

- Last cycle's broken doc example is fixed: usage.md:862 now carries `llm => #{}`, and `usage_real_provider_example_envelope_carries_llm_test` (soma_b2_no_socket_tests.erl:112) pins it so a future edit can't drop it again. Closed.
- The real path needs both a `model_config` on the actor and an `llm` key on every envelope, even when `llm => #{}` is empty and ignored. That's the seam B.2 chose so v0.5 stays byte-for-byte. CLI.2 (`soma ask`) is the named consumer — it sends "a plain prompt" and expects a real call. Decide there whether `soma ask` always stamps `llm => #{}`, or the actor takes the LLM path from the prompt payload alone. Not a blocker for #119.

## Nits

None.

## Functional evidence
- Criterion 1 — pass: `build_call_opts/2` real-provider clause (soma_actor.erl:827) returns `#{provider => openai_compat, base_url => BaseUrl, model => Model, ...}`; `real_provider_model_config_builds_routing_opts_test` asserts all three keys (soma_actor_call_opts_tests.erl:14-16). `perform_call/1` routes `provider := openai_compat` to `soma_llm_openai:chat/1` (soma_llm_call.erl:34).
- Criterion 2 — pass: builder derives `messages => [#{role => <<"user">>, content => Prompt}]` from `payload.prompt`; `real_provider_opts_carry_prompt_as_user_message_test` asserts the non-empty user-message list (soma_actor_call_opts_tests.erl:30-34).
- Criterion 3 — pass: mock clause `build_call_opts(_ModelConfig, Envelope) -> maps:get(llm, Envelope, #{})` (soma_actor.erl:846); `empty_or_directive_model_config_returns_mock_opts_unchanged_test` asserts the `llm` map returns unchanged for `#{}` and `#{directive => proposal}` (soma_actor_call_opts_tests.erl:46-48).
- Criterion 4 — pass: CT `real_provider_actor_completes_llm_task_through_openai_no_socket` starts an actor with a real-provider `model_config` carrying `response => {200, Body}`, drives `send/2`, asserts `get_task_result/2` returns `#{kind := reply, text := Content}` parsed from `choices[0].message.content` (soma_actor_real_provider_SUITE.erl:84-87). All 239 CT passed.
- Criterion 5 — pass: CT `mock_model_config_completes_llm_task_same_result_and_events` starts an actor with `model_config => #{}`, drives the mock proposal envelope, asserts result `#{kind := reply, text := <<"here is your answer">>}` and the v0.5 event set (`actor.*`, `llm.*`, `proposal.created`, `proposal.approved`, no `run.started`) (soma_actor_real_provider_SUITE.erl:120-129).
- Criterion 6 — pass: CT `api_key_appears_in_no_emitted_event` uses sentinel `<<"sk-secret-sentinel-do-not-leak">>` as the api_key, pulls every event payload under the correlation_id, asserts `term_contains` finds the sentinel in none (soma_actor_real_provider_SUITE.erl:173). The api_key only reaches `soma_llm_openai:build_request/1`'s Authorization header (soma_llm_openai.erl:15-18), never an `emit/3` payload.
- Criterion 7 — pass: EUnit `real_provider_suite_uses_response_seam_only_test` reads the suite source, asserts `count("#{provider => openai_compat") == count("response =>")` and `> 0`, and zero `http://` / `https://` literals (soma_b2_no_socket_tests.erl:50-54).
- Criterion 8 — pass: usage.md gained "Starting an actor with a real LLM provider" (usage.md:821). The example envelope carries `llm => #{}` (usage.md:862), so the documented `send/2` takes the llm-call path and produces the claimed `{ok, #{kind => reply, text => <<"Hello!">>}}`. Two guards: `usage_documents_actor_real_provider_config_test` (markers + `soma_llm_smoke:run()`) and `usage_real_provider_example_envelope_carries_llm_test` (the `llm =>` key sits in the prompt-envelope window) (soma_b2_no_socket_tests.erl:73,112).
- Criterion 9 — pass: `rebar3 eunit` 205 tests 0 failures; `rebar3 ct` all 239 passed; `rebar3 dialyzer` 4 warnings, all in untouched files (`soma_lfe_reader.erl`, `soma_tool_call.erl` — the documented baseline of 4), none in `soma_actor.erl`. No socket opened in the gate (the response seam short-circuits httpc before the live path).
