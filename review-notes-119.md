### Claude

## Verdict
changes-requested

## Real issues

- Criterion 6's test is a false guard. `api_key_appears_in_no_emitted_event` pulls only the `payload` field of each event (soma_actor_real_provider_SUITE.erl:170) and scans that for the sentinel. But the actor's `emit/3` merges its `Extra` map at the top level of the event next to `actor_id` / `event_type` — it never nests anything under `payload` (soma_actor.erl:1085-1092). The event store's `normalize/1` then stamps `payload => undefined` on every actor event (soma_event_store.erl:125-132). So for every event under the correlation, `maps:get(payload, E, #{})` is `undefined`, `term_contains(undefined, Sentinel)` hits the catch-all `false` clause, and `lists:any` is always `false`. The assertion can't fail. Put the sentinel in `llm.started`'s top-level fields tomorrow and the test still passes green. Scan the whole event map (every key and value), not `payload`. The production code is correct today — the api_key reaches only `soma_llm_openai:build_request/1`'s Authorization header — but this test does not prove it.

## Questions

- The real path needs both a `model_config` on the actor and an `llm` key on every envelope, even when `llm => #{}` is empty and ignored. That's the seam B.2 chose so v0.5 stays byte-for-byte. CLI.2 (`soma ask`) is the named consumer — it sends "a plain prompt" and expects a real call. Decide there whether `soma ask` always stamps `llm => #{}`, or the actor takes the LLM path from the prompt payload alone. Not a blocker for #119.
- Criterion 5's test asserts the event *set* (presence of `actor.*`, `llm.*`, `proposal.created`, `proposal.approved`, absence of `run.started`), not byte equality with v0.5. Looser than "the same events" reads, but a fair artifact. Leaving it.

## Nits

None.

## Functional evidence
- Criterion 1 — pass: `build_call_opts/2` real-provider clause (soma_actor.erl:827) returns `#{provider => openai_compat, base_url => BaseUrl, model => Model, ...}`; `real_provider_model_config_builds_routing_opts_test` asserts all three keys (soma_actor_call_opts_tests.erl:14-16). `perform_call/1` routes `provider := openai_compat` to `soma_llm_openai:chat/1` (soma_llm_call.erl:34).
- Criterion 2 — pass: builder derives `messages => [#{role => <<"user">>, content => Prompt}]` from `payload.prompt`; `real_provider_opts_carry_prompt_as_user_message_test` asserts the non-empty user-message list (soma_actor_call_opts_tests.erl:30-34).
- Criterion 3 — pass: mock clause `build_call_opts(_ModelConfig, Envelope) -> maps:get(llm, Envelope, #{})` (soma_actor.erl:846); `empty_or_directive_model_config_returns_mock_opts_unchanged_test` asserts the `llm` map returns unchanged for `#{}` and `#{directive => proposal}` (soma_actor_call_opts_tests.erl:46-48).
- Criterion 4 — pass: CT `real_provider_actor_completes_llm_task_through_openai_no_socket` starts an actor with a real-provider `model_config` carrying `response => {200, Body}`, drives `send/2`, asserts `get_task_result/2` returns `#{kind := reply, text := Content}` parsed from `choices[0].message.content` (soma_actor_real_provider_SUITE.erl:84-87). All 239 CT passed.
- Criterion 5 — pass: CT `mock_model_config_completes_llm_task_same_result_and_events` starts an actor with `model_config => #{}`, drives the mock proposal envelope, asserts result `#{kind := reply, text := <<"here is your answer">>}` and the v0.5 event set (`actor.*`, `llm.*`, `proposal.created`, `proposal.approved`, no `run.started`) (soma_actor_real_provider_SUITE.erl:120-129).
- Criterion 6 — fail: `api_key_appears_in_no_emitted_event` scans only `maps:get(payload, E, #{})` (soma_actor_real_provider_SUITE.erl:170), which is `undefined` for every actor event because `emit/3` merges fields at the top level (soma_actor.erl:1085-1092) and `normalize/1` sets `payload => undefined` (soma_event_store.erl:125-132). The assertion is trivially true and catches no leak. The criterion holds in production code, but the test does not prove it — scan the full event map.
- Criterion 7 — pass: EUnit `real_provider_suite_uses_response_seam_only_test` reads the suite source, asserts `count("#{provider => openai_compat") == count("response =>")` and `> 0`, and zero `http://` / `https://` literals (soma_b2_no_socket_tests.erl:50-54).
- Criterion 8 — pass: usage.md gained "Starting an actor with a real LLM provider" (usage.md:821). The example envelope carries `llm => #{}` (usage.md:862), so the documented `send/2` takes the llm-call path and produces the claimed `{ok, #{kind => reply, text => <<"Hello!">>}}`. Two guards: `usage_documents_actor_real_provider_config_test` (markers + `soma_llm_smoke:run()`) and `usage_real_provider_example_envelope_carries_llm_test` (the `llm =>` key sits in the prompt-envelope window) (soma_b2_no_socket_tests.erl:73,112).
- Criterion 9 — pass: `rebar3 eunit` 205 tests 0 failures; `rebar3 ct` all 239 passed; `rebar3 dialyzer` 4 warnings, all in untouched files (`soma_lfe_reader.erl`, `soma_tool_call.erl` — the documented baseline of 4, neither changed on this branch), none in `soma_actor.erl`. No socket opened in the gate (the response seam short-circuits httpc before the live path).
