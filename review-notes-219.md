### Claude

## Verdict
approve

## Real issues

None.

## Questions

- `docs/contracts/tool-ask-actor-test-contract.md` calls the `system_prompt` ordering work a "fix." It's new behavior (no prior `system_prompt` field existed), not a bug fix. Doesn't affect correctness, just a word choice in the doc.

## Nits

- `soma_actor:build_call_opts/2`'s planning branch uses `lists:split(length(UserMessages) - 1, UserMessages)` to peel off the trailing user message before inserting the planning system message. Works because `BaseMessages` is always exactly 1 or 2 elements here, but the length-based split reads less directly than a `[Head | _] = lists:reverse(...)` or matching `BaseMessages` at the point it's built (single vs. two-message case) would.

## Functional evidence

- Criterion 1 — pass: `soma_tool_ask_actor_SUITE:ask_actor_shorthand_file_read_to_file_write_writes_reply_text` runs `file_read -> ask_actor(message => {from_step, read}) -> file_write(bytes => {from_step, ask})` against a target actor with mock `directive => proposal, output => #{kind => reply, text => <<"model reply">>}`, asserts `file:read_file` returns `{ok, <<"model reply">>}` and the parent session stays alive. `rebar3 ct --suite apps/soma_actor/test/soma_tool_ask_actor_SUITE` → all 12 tests passed.
- Criterion 2 — pass: `soma_tool_ask_actor_SUITE:ask_actor_shorthand_uses_actor_mock_model_config_no_socket` calls shorthand `ask_actor` against a target actor whose `model_config` carries only `directive`/`output` (no `provider`/`base_url`), asserts the child task's event trail (via `by_correlation/2`) includes `llm.started`, `llm.succeeded`, `proposal.created`, and asserts the step output is the reply text — same CT run, green.
- Criterion 3 — pass: `soma_tool_ask_actor_SUITE:ask_actor_shorthand_non_reply_result_unchanged` uses a target actor mock `directive => success, output => #{raw => <<"kept">>}` and asserts the parent step output equals `#{raw => <<"kept">>}` exactly (`unwrap_shorthand_reply/2` in `apps/soma_actor/src/soma_tool_ask_actor.erl:87-91` only unwraps `#{kind := reply, text := Text}`) — same CT run, green.
- Criterion 4 — pass: `soma_tool_ask_actor_SUITE:ask_actor_message_and_envelope_rejected` sends `#{target, message, envelope}` together, asserts terminal `run.failed` with reason `{invalid_ask_actor_input, message_and_envelope}` (`normalize_input(#{message := _, envelope := _}) -> {error, {invalid_ask_actor_input, message_and_envelope}}` at `apps/soma_actor/src/soma_tool_ask_actor.erl:42-43`), then asserts the session completes a later echo step — same CT run, green.
- Criterion 5 — pass: `soma_tool_ask_actor_SUITE:ask_actor_shorthand_non_binary_message_rejected` sends `message => #{bad => value}`, asserts terminal `run.failed` with reason `{invalid_ask_actor_input, invalid_message}`, then asserts the session completes a later echo step — same CT run, green.
- Criterion 6 — pass: `soma_actor_call_opts_tests:real_provider_system_prompt_precedes_user_message_test` calls `soma_actor:build_call_opts/2` with `provider => openai_compat` and `system_prompt => <<"custom">>`, asserts `messages` is exactly `[#{role => <<"system">>, content => <<"custom">>}, #{role => <<"user">>, content => Prompt}]`. `rebar3 eunit --module=soma_actor_call_opts_tests,soma_tool_ask_actor_contract_tests` → 14 tests, 0 failures.
- Criterion 7 — pass: `soma_actor_call_opts_tests:planning_system_prompt_orders_custom_then_planning_then_user_test_` sets `plan => true` plus `system_prompt => <<"custom">>`, asserts the three-message list is `[custom-system, planning-system(contains "(run-steps"), user]` in that order — same EUnit run, green.
- Criterion 8 — pass: `docs/contracts/tool-ask-actor-test-contract.md` has an `## Issue #219` section (lines 32-48) naming all seven test cases above; `soma_tool_ask_actor_contract_tests:issue_219_contract_names_all_proofs_test` reads the file and asserts every module/case name string is present — same EUnit run, green.

Full gate: `rebar3 eunit` → 371 tests, 0 failures. `rebar3 ct` → 388 tests passed (fresh `_build/test` removed before running, per prior flake note in project memory).
