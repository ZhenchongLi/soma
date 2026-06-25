# [cc] v0.5.6: actor-to-actor messages — correlation_id across actors (P12)

## Current state

Three places treat `actor_message` as a thing that does not exist yet.

`soma_proposal:normalize/1` (`apps/soma_actor/src/soma_proposal.erl`) has clauses for
`reply`, `run_steps`, `reject`, and `ask`. Anything else falls through to the
`#{kind := Kind}` clause and comes back as `{error, [#{code => unknown_kind}]}`. So a
proposal carrying `kind => actor_message` is rejected today.

`soma_policy:check/2` (`apps/soma_actor/src/soma_policy.erl`) has clauses for `reply`,
`reject`, `ask`, and `run_steps`. There is no `actor_message` clause and no catch-all, so
calling `check/2` with an `actor_message` proposal raises `function_clause`.

`soma_actor`'s approved-proposal branch (the `proposal.approved` block inside the
`{llm_result, ...}` handler in `apps/soma_actor/src/soma_actor.erl`) branches on
`maps:get(kind, Proposal)`: `run_steps` starts a run, everything else is treated as a
toolless kind that completes in place with the proposal as its result. There is no path
that, on approval, sends an envelope to another actor.

One existing test pins the old behaviour. `soma_proposal_tests` ·
`test_actor_message_kind_errors` asserts `actor_message` normalizes to an error. It happens
to use a malformed shape (`to => <<"other">>`, a `text` field, no `payload`), so under the
new normalize it would still fail. But the message and intent of that test are now wrong —
it claims the *kind* is unsupported. It needs to be repurposed into a real
missing-field proof so it does not silently misdescribe the behaviour.

The mock LLM and the name-allowlist policy are unchanged. This slice adds no provider, no
persistence, no actor-id registry.

## Approach

Target state: one actor (A1) whose mock returns an approved `actor_message` proposal sends
an envelope to a second actor (A2) whose pid the proposal names. The sender's
`correlation_id` rides into A2's new task. Querying the event store by that one id returns
both actors' events.

`soma_proposal:normalize/1` gains a clause:
`normalize(#{kind := actor_message, to := To, payload := Payload}) when is_pid(To), is_map(Payload)`.
It returns `{ok, #{kind => actor_message, to => To, payload => Payload}}`. Two failure
clauses cover the missing fields. Order matters: the new success clause and the missing-field
clauses must sit before the existing `#{kind := Kind}` catch-all, otherwise a missing-field
`actor_message` would fall through to `unknown_kind`. The missing-field clauses match
`#{kind := actor_message}` and report which required field is absent, mirroring how the
`reply`-missing-`text` clause already works.

`soma_policy:check/2` gains `check(#{kind := actor_message}, _Policy) -> allow`. An
`actor_message` carries no tools, so the name allowlist has nothing to check — same shape
as the `reply` / `reject` / `ask` clauses already there. This must land before any
catch-all and before the `run_steps` clauses, since those expect a `steps` key.

`soma_actor`'s approved-proposal branch gains an `actor_message` arm next to `run_steps`,
inside the `allow` case after `proposal.approved` is emitted. The arm:

1. Emits `proposal.executed` for the task (same shape the `run_steps` path emits, carrying
   `correlation_id` and `llm_call_id`).
2. Builds a delivery envelope `#{type => <<"actor.message">>, payload => Payload,
   correlation_id => CorrId}` where `CorrId` is the sender task's `correlation_id` and
   `Payload` comes from the proposal.
3. Calls `soma_actor:send(To, Envelope)` — the normal entry point, so A2 runs the envelope
   through its own `idle/3` dispatch with no layer bypassed. This is fire-and-forget: A1
   does not wait on A2's result.
4. Marks the sender task `completed` and stores the proposal as its result, then releases
   any parked `ask` waiter. The send already happened, so the sender's work is done on
   delivery.

A2 needs no new code. `resolve_correlation_id/2` already reads an envelope's
`correlation_id` when present, so the delivered envelope's id becomes A2's task's id. A2
emits its usual `actor.message.received` / `actor.task.accepted` under that id. With both
actors sharing one event store, `by_correlation/2` for that id returns A1's chain and A2's
chain together.

The one reachable failure path is a malformed `actor_message` proposal. It fails
`soma_proposal:normalize/1`, so it never reaches the approved-proposal branch — it takes the
existing `{invalid_proposal, Diagnostics}` arm, marks A1's task `failed`, and emits no
`proposal.executed`. No envelope is sent to A2. A1 stays alive. No new actor code is needed
for this either; the criterion just asserts the existing failure path delivers nothing.

A policy-*rejection* of an `actor_message` is not reachable: the proposal carries no tools,
so the name allowlist always allows it. The issue already dropped that criterion. I keep it
dropped.

## Acceptance criteria → tests

The two-actor proofs need a suite that starts two actors against one shared event store.
None of the existing suites does this, so the actor-side proofs land in a new
`soma_actor_message_SUITE` in `apps/soma_actor/test/`, set up like
`soma_proposal_exec_SUITE` (boot `soma_runtime` for the shared event store and
`soma_run_sup`, start actors through `soma_actor_sup:start_actor/1`, drive A1 through the
real `soma_actor:send/2` with a `proposal` llm directive whose proposal's `to` is A2's pid).
The pure normalize/policy proofs land in the existing `soma_proposal_tests` and
`soma_policy_tests` EUnit modules.

### Criterion 1 — `actor_message` with pid `to` and map `payload` normalizes ok
- Call chain: none (direct module call to a pure function)
- Test entry: `soma_proposal:normalize/1` directly
- Test: `test_actor_message_normalizes_ok` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 2 — `actor_message` missing `to` errors
- Call chain: none (direct module call to a pure function)
- Test entry: `soma_proposal:normalize/1` directly
- Test: `test_actor_message_missing_to_errors` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 3 — `actor_message` missing `payload` errors
- Call chain: none (direct module call to a pure function)
- Test entry: `soma_proposal:normalize/1` directly
- Test: `test_actor_message_missing_payload_errors` in `apps/soma_actor/test/soma_proposal_tests.erl`
- Note: this replaces the now-stale `test_actor_message_kind_errors`. That old case
  asserted the *kind* is unsupported, which is no longer true. The pin test references
  `test_actor_message_kind_errors` by name, so renaming it forces the pin-test update in
  criterion 12 to drop the old name and add the three new ones.

### Criterion 4 — policy allows a normalized `actor_message`
- Call chain: none (direct module call to a pure function)
- Test entry: `soma_policy:check/2` directly
- Test: `actor_message_returns_allow_test` in `apps/soma_actor/test/soma_policy_tests.erl`

### Criterion 5 — A2 accepts a task for the delivered envelope and emits `actor.task.accepted`
- Call chain: A1 mock returns proposal → `soma_llm_call` worker → A1 `{llm_result, ...}`
  handler → `soma_proposal:normalize/1` → `soma_policy:check/2` → A1 `actor_message` arm →
  `soma_actor:send(A2, Envelope)` → A2 `idle/3` `{send, _}` → A2 emits `actor.task.accepted`
- Test entry: `soma_actor:send(A1, Envelope)` (the full chain runs, no layer bypassed)
- Test: `delivered_message_accepted_by_a2_emits_task_accepted` in
  `apps/soma_actor/test/soma_actor_message_SUITE.erl`

### Criterion 6 — A2's delivered task carries A1's `correlation_id`
- Call chain: same as criterion 5, ending at A2's `actor.task.accepted` event payload
- Test entry: `soma_actor:send(A1, Envelope)`
- Test: `delivered_task_inherits_a1_correlation_id` in
  `apps/soma_actor/test/soma_actor_message_SUITE.erl`
- Note: read A2's `correlation_id` off the `actor.task.accepted` event A2 emitted, and assert
  it equals the `correlation_id` A1's sender task ran under.

### Criterion 7 — `by_correlation/2` returns both A1's and A2's events
- Call chain: same as criterion 5, then `soma_event_store:by_correlation/2` reads the shared store
- Test entry: `soma_actor:send(A1, Envelope)`, then `by_correlation/2` for A1's correlation id
- Test: `by_correlation_returns_both_actors_events` in
  `apps/soma_actor/test/soma_actor_message_SUITE.erl`
- Note: assert the returned events carry both A1's `actor_id` and A2's `actor_id` under the
  one id.

### Criterion 8 — A1 emits `proposal.executed` for the approved `actor_message`
- Call chain: same as criterion 5, up to A1's `actor_message` arm emitting `proposal.executed`
- Test entry: `soma_actor:send(A1, Envelope)`
- Test: `a1_emits_proposal_executed_for_actor_message` in
  `apps/soma_actor/test/soma_actor_message_SUITE.erl`

### Criterion 9 — A1's `actor_message` task reaches `completed`, A1 stays alive
- Call chain: same as criterion 5, ending at A1's task status after the arm marks it `completed`
- Test entry: `soma_actor:send(A1, Envelope)`, then `get_task_status/2` for A1's task
- Test: `a1_actor_message_task_completed_actor_alive` in
  `apps/soma_actor/test/soma_actor_message_SUITE.erl`
- Note: assert `get_task_status/2` reads `completed` and `is_process_alive(A1)` is true.

### Criterion 10 — a malformed `actor_message` delivers nothing to A2, A1 stays alive
- Call chain: A1 mock returns a malformed proposal → A1 `{llm_result, ...}` handler →
  `soma_proposal:normalize/1` returns `{error, _}` → A1 `{invalid_proposal, _}` arm (the
  send chain to A2 is never reached)
- Test entry: `soma_actor:send(A1, Envelope)` with a malformed-proposal mock
- Test: `malformed_actor_message_delivers_nothing_actor_alive` in
  `apps/soma_actor/test/soma_actor_message_SUITE.erl`
- Note: assert A1's task reaches `failed`, no event in the store carries A2's `actor_id`,
  and `is_process_alive(A1)` is true. Give A1 and A2 distinct `actor_id`s so "no delivery"
  is checkable by A2's id never appearing.

### Criterion 11 — contract doc gains a v0.5.6 section mapping each proof, notes P12
- Call chain: none (documentation deliverable)
- Test entry: editing `docs/contracts/v0.5-test-contract.md`
- Test: covered by criterion 12's pin assertions (the doc itself is not a code test)

### Criterion 12 — pin test names the v0.5.6 section and every new case
- Call chain: none (direct source-file read)
- Test entry: `soma_llm_call_SUITE` · `pins_v0_5_test_contract_maps_each_proof` reads the doc
  off the call chain
- Test: `pins_v0_5_test_contract_maps_each_proof` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`
- Note: add `<<"v0.5.6">>` and `<<"soma_actor_message_SUITE">>` to the doc-contains checks,
  drop `<<"test_actor_message_kind_errors">>` from the `Cases` list, and add the three new
  `soma_proposal_tests` case names, the `actor_message_returns_allow_test` case name, and the
  six `soma_actor_message_SUITE` case names.

### Criterion 13 — `rebar3 eunit && rebar3 ct` is green
- Call chain: none (full gate)
- Test entry: the merge gate
- Test: the whole suite set, run as `rebar3 eunit && rebar3 ct`

## Risks & trade-offs

`to` is a raw pid. If A2 has died by the time A1's arm runs `send/2`, the
`gen_statem:call` inside `send/2` exits with `{noproc, _}` (or times out). A1's arm runs
inside A1's own `{llm_result, ...}` handler, so an unhandled exit there would crash A1 —
the opposite of the actor-survival contract. The arm should treat a failed delivery as task
data (catch the call exit, mark the sender task `failed`), not let it take A1 down. This is
not in the issue's acceptance criteria, so I am not adding a criterion for it, but the Dev
should not let `send/2` to a dead A2 crash A1. Flagging it so it is a deliberate choice, not
an oversight.

Renaming `test_actor_message_kind_errors` to `test_actor_message_missing_payload_errors`
changes a case the pin test names. The two changes have to land together or the pin test
goes red. The criterion ordering (rename in 3, pin update in 12) keeps them in one Dev's
view.

The delivery envelope's `type` is a fixed `<<"actor.message">>`. The issue's design says
the envelope is shaped `#{type, payload, correlation_id}` but does not pin the `type` value.
A2 does not branch on `type` (it only requires the key to be present), so any binary works.
I pick a descriptive constant rather than echoing the proposal's payload type, so the trail
reads honestly as an actor-to-actor delivery.
