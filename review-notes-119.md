### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The real path needs both a `model_config` on the actor and an `llm` key on every envelope, even when `llm => #{}` is empty and ignored. That's the seam B.2 chose so v0.5 stays byte-for-byte. CLI.2 (`soma ask`) is the named consumer — it sends "a plain prompt" and expects a real call. Decide there whether `soma ask` always stamps `llm => #{}`, or the actor takes the LLM path from the prompt payload alone. Not a blocker for #119.
- The earlier round's api-key leak guard scanned only `payload`, which is `undefined` on every actor event, so the check was inert. Fixed in commit 4aab113 — `term_contains` now walks every key and value of every event map. Keep that pattern for any future secret-leak guard.

## Nits
- `soma_actor_call_opts_tests.erl:10,26` uses an `https://` base_url literal in the pure-builder tests. It is never dialed (the builder is pure, the SUITE uses a scheme-less host plus the response seam), so the no-socket guard scopes itself to the SUITE only. Harmless, slightly noisy.
- `build_call_opts/2` hard-codes one user message, no system prompt, no history. Fine for `soma ask`; a multi-turn actor will need a richer builder. Already flagged in the design's trade-offs.

## Functional evidence
- Criterion 1 — pass: `build_call_opts/2` real-provider clause (soma_actor.erl:823) returns `#{provider => openai_compat, base_url => BaseUrl, model => Model, messages => [...]}`; `real_provider_model_config_builds_routing_opts_test` asserts all three routing keys (soma_actor_call_opts_tests.erl:14-16). `perform_call/1` routes `provider := openai_compat` to `soma_llm_openai:chat/1`.
- Criterion 2 — pass: builder derives `messages => [#{role => <<"user">>, content => Prompt}]` from `payload.prompt`; `real_provider_opts_carry_prompt_as_user_message_test` asserts the non-empty user-message list equals `[#{role => <<"user">>, content => <<"what is soma?">>}]` (soma_actor_call_opts_tests.erl:30-34).
- Criterion 3 — pass: mock clause `build_call_opts(_ModelConfig, Envelope) -> maps:get(llm, Envelope, #{})` (soma_actor.erl:846); `empty_or_directive_model_config_returns_mock_opts_unchanged_test` asserts the `llm` map returns unchanged for `#{}` and `#{directive => proposal}` (soma_actor_call_opts_tests.erl:46-48).
- Criterion 4 — pass: CT `real_provider_actor_completes_llm_task_through_openai_no_socket` starts an actor with a real-provider `model_config` carrying `response => {200, Body}`, drives `send/2`, asserts `get_task_result/2` returns `#{kind := reply, text := Content}` parsed from `choices[0].message.content` (SUITE:84-87). CT 239 passed.
- Criterion 5 — pass: CT `mock_model_config_completes_llm_task_same_result_and_events` starts an actor with `model_config => #{}`, drives the mock proposal envelope, asserts result `#{kind := reply, text := <<"here is your answer">>}` and the v0.5 event set (`actor.*`, `llm.*`, `proposal.created`, `proposal.approved`, no `run.started`) (SUITE:120-129).
- Criterion 6 — pass: `api_key_appears_in_no_emitted_event` uses sentinel `<<"sk-secret-sentinel-do-not-leak">>` and asserts `term_contains` finds it in no event — recursive scan over every key/value of every event map, not just `payload` (SUITE:174, fixed in commit 4aab113).
- Criterion 7 — pass: EUnit `real_provider_suite_uses_response_seam_only_test` reads the suite source, asserts `count("#{provider => openai_compat") == count("response =>")` and `> 0`, and zero `http://` / `https://` literals (soma_b2_no_socket_tests.erl:50-54). No `gen_tcp`/`httpc` in any actor test.
- Criterion 8 — pass: usage.md gained "Starting an actor with a real LLM provider" (usage.md:821). The example envelope carries `llm => #{}` (usage.md:862), so the documented `send/2` takes the llm-call path and produces the claimed `{ok, #{kind => reply, text => <<"Hello!">>}}`. Guards: `usage_documents_actor_real_provider_config_test` (markers + `soma_llm_smoke:run()`) and `usage_real_provider_example_envelope_carries_llm_test` (soma_b2_no_socket_tests.erl:73,112).
- Criterion 9 — pass: `rebar3 eunit` 205 tests 0 failures; `rebar3 ct` all 239 passed; `rebar3 dialyzer` 4 warnings, all in untouched files (`soma_lfe_reader.erl` x3, `soma_tool_call.erl` x1 — the documented baseline, no diff on this branch), none in `soma_actor.erl`. No socket opened (the response seam short-circuits httpc).
