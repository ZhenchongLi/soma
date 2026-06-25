### Claude

## Verdict
approve

## Real issues

None.

## Questions

- An `actor_message` with both keys present but a non-pid `to` or a non-map `payload` skips both missing-field clauses and falls to the `#{kind := Kind}` catch-all. It still returns `{error, _}`, but the diagnostic reads `unknown_kind` with `kind => actor_message` — a misleading code for a wrong-type field. Criterion 10's malformed mock uses exactly this shape (`to => <<"actor-a2">>`), so the failure path works, but the diagnostic lies about why. Worth a typed-field diagnostic later. Not a blocker.
- `execute_actor_message` runs `soma_actor:send(To, Delivery)` as a synchronous `gen_statem:call` from inside A1's own `info` callback. A1 blocks until A2's `idle/3` returns. With A2 busy on a slow run, A1 stalls for the call's duration. The dead-receiver exit is caught, so survival holds; but a live-but-slow A2 still stalls A1. Fire-and-forget would want a cast. Out of scope here.

## Nits

- `try soma_actor:send(To, Delivery) of _ -> ...` catches `exit` only. A pid `to` can only exit (`{noproc,_}`), so this is correct today. If `to` ever accepts a registered name, an `error:badarg` would escape uncaught.

## Functional evidence
- Criterion 1 — pass: `soma_proposal.erl:30` clause `normalize(#{kind := actor_message, to := To, payload := Payload}) when is_pid(To), is_map(Payload)` returns `{ok, ...}`; proven by `soma_proposal_tests` · `test_actor_message_normalizes_ok` (EUnit green).
- Criterion 2 — pass: `soma_proposal.erl:38` `not is_map_key(to, Raw)` clause returns `{error, [#{code => missing_required_field, field => to}]}`; proven by `soma_proposal_tests` · `test_actor_message_missing_to_errors`.
- Criterion 3 — pass: `soma_proposal.erl:43` `not is_map_key(payload, Raw)` clause returns `{error, [#{code => missing_required_field, field => payload}]}`; proven by `soma_proposal_tests` · `test_actor_message_missing_payload_errors`.
- Criterion 4 — pass: `soma_policy.erl:22` `check(#{kind := actor_message}, _Policy) -> allow`; proven by `soma_policy_tests` · `actor_message_returns_allow_test` under a restrictive `allowed_tools => [echo]`.
- Criterion 5 — pass: `soma_actor_message_SUITE` · `delivered_message_accepted_by_a2_emits_task_accepted` drives A1 through the real `send/2` and waits for A2's `actor.task.accepted` event under A2's actor_id (CT green).
- Criterion 6 — pass: `soma_actor_message_SUITE` · `delivered_task_inherits_a1_correlation_id` reads `correlation_id` off A2's `actor.task.accepted` event and asserts it equals A1's `corr-a1-send`.
- Criterion 7 — pass: `soma_actor_message_SUITE` · `by_correlation_returns_both_actors_events` — `by_correlation/2` for one id yields events carrying both `<<"actor-a1">>` and `<<"actor-a2">>`.
- Criterion 8 — pass: `soma_actor.erl:583` `execute_actor_message` emits `proposal.executed`; proven by `soma_actor_message_SUITE` · `a1_emits_proposal_executed_for_actor_message`.
- Criterion 9 — pass: `soma_actor_message_SUITE` · `a1_actor_message_task_completed_actor_alive` — `get_task_status/2` reads `completed` and `is_process_alive(A1)` true.
- Criterion 10 — pass: `soma_actor_message_SUITE` · `malformed_actor_message_delivers_nothing_actor_alive` — non-pid `to` takes the `{invalid_proposal, _}` arm, A1 task `failed`, no A2 event beyond `actor.started`, A1 alive.
- Criterion 11 — pass: `docs/contracts/v0.5-test-contract.md` gains a "v0.5.6 — actor-to-actor messages ... (delivers P12)" section mapping criteria 1–10 to suite · case in two tables.
- Criterion 12 — pass: `soma_llm_call_SUITE` · `pins_v0_5_test_contract_maps_each_proof` adds `<<"v0.5.6">>`, `<<"soma_actor_message_SUITE">>`, the four pure-proof case names and six suite case names; drops `<<"test_actor_message_kind_errors">>` (CT green).
- Criterion 13 — pass: `rebar3 eunit` = 135 tests, 0 failures; `rebar3 ct` = All 192 tests passed.
