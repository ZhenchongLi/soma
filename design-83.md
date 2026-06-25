# v0.5.2: soma_proposal:normalize/1 — proposals as validated data, not execution

## Current state

v0.5.1 stood up the supervised LLM-call worker `soma_llm_call`. The worker runs
one mock call from a `directive` in the `llm` map and reports `{ok, Output}` back
to the actor. The actor records that output verbatim as the task result and emits
`llm.succeeded`. `Output` is an opaque term — the actor never looks inside it and
never gives it a shape.

The mock seam `soma_llm_call:perform_call/1` handles four directives today:
`success` (returns the configured `output`), `slow`, `hang`, `crash`. None of
them returns anything that looks like a decision the actor should act on. There
is no module that says "this is what a proposal is" and no validation of LLM
output before it becomes a task result.

The runtime already has two pure normalize/compile boundaries that show the shape
to copy. `soma_tool_manifest:normalize/1` takes a raw map and returns
`{ok, Normalized}` or `{error, Reason}`, with no processes and no events.
`soma_lfe:compile/2` returns `{ok, Map}` or `{error, [Diagnostic]}` where each
diagnostic is a map. The issue locks the proposal boundary to the list-of-
diagnostics shape: `normalize(Raw) -> {ok, Proposal} | {error, [Diagnostic]}`.

What is missing: a `soma_proposal` module that validates LLM output into a tagged
proposal, plus the actor wiring that runs a returned proposal through it, stores
the normalized proposal as the task result, and emits `proposal.created`.

## Approach

Add `soma_proposal:normalize/1` as a pure module, then wire the actor's existing
`llm_result` success path to run the worker output through it.

**The module.** `soma_proposal` lives in `apps/soma_actor/src/` — the actor uses
it, the runtime never imports the actor, so this keeps the one-way dependency.
It exports `normalize/1`. It mirrors `soma_tool_manifest`'s structure: branch on
the tag field, check the required fields for that tag, return `{ok, Proposal}` or
`{error, [Diagnostic]}`. The list-of-diagnostics shape comes from
`soma_lfe:compile/2`. For this slice each error path returns a one-element list —
one diagnostic per failure — which is enough to satisfy the criteria and leaves
room for multi-diagnostic results later without a signature change.

The tag field is `kind`, kept separate from the envelope's `type` so the two
never collide. Four kinds are recognized:

- `#{kind => reply, text => binary()}` — direct reply, no tools.
- `#{kind => run_steps, steps => [StepMap]}` — a proposed v0.1 step list.
- `#{kind => reject, reason => binary()}` — decline.
- `#{kind => ask, question => binary()}` — ask for clarification.

A `run_steps` proposal's steps go through the same step-shape check the actor
already uses for envelope steps: each step must be a map with an `id` and a
`tool` key. The check itself (`valid_step/1` in `soma_actor.erl`, added by #73)
is small. The design choice is to apply the identical rule inside `soma_proposal`
rather than reach across into the actor — the proposal module stays pure and
self-contained, and the duplicated rule is two `maps:is_key` calls. The steps are
validated, not run.

Two kinds of input are rejected. An unknown `kind` (anything outside the four)
returns `{error, [Diagnostic]}`. `kind => actor_message` is rejected the same way
— it is not a supported kind in this slice. It is deferred to v0.5.6, where
actor-to-actor delivery and cross-actor `correlation_id` propagation get built
and its `to` / `payload` shape can be designed against a real consumer. A
proposal missing a required field for its kind (a `reply` with no `text`) also
returns `{error, [Diagnostic]}`.

**The mock seam.** `soma_llm_call:perform_call/1` gains a directive that returns
a raw proposal. The shape: the `llm` map carries the proposal under a key (a
`proposal` directive whose `output` is the raw proposal map), and `perform_call`
returns `{ok, RawProposal}`. This keeps the worker directive-driven and the
proposal entirely in the `llm` map the test supplies, so the test controls
exactly which proposal comes back. No proposal logic lives in the worker — it
returns the raw map unchanged, same as the `success` directive returns its
output unchanged.

**The actor wiring.** The actor's `idle(info, {llm_result, LlmCallId, _, {ok,
Output}}, Data)` clause runs today: clear the timer and monitor, record the task
`completed` with `Output` as the result, emit `llm.succeeded`, reply any waiter.
The change: after emitting `llm.succeeded`, run `Output` through
`soma_proposal:normalize/1`.

- On `{ok, Proposal}`: store `Proposal` (the normalized proposal, not the raw
  output) as the task result so `get_task_result/2` returns it, keep the task
  `completed`, and emit `proposal.created` carrying the task's `correlation_id`
  and the proposal `kind`.
- On `{error, _Diagnostics}`: set the task terminal `failed`, do **not** emit
  `proposal.created`, and leave the actor alive to take the next envelope.

`llm.succeeded` still marks "the call returned a result" and fires in both cases.
`proposal.created` marks "a valid proposal was normalized and recorded" and fires
only on success. This is decision 2 in the issue and opens the `proposal.*`
family that v0.5.3+ extends (`proposal.approved` / `rejected` / `executed`).

No `soma_run` is started for a `run_steps` proposal. The proposed steps are
recorded as the task result, not run. Executing a proposal is later v0.5 work.

**The contract doc.** `docs/contracts/v0.5-test-contract.md` gains a v0.5.2
section mapping each proof below to its suite and case. The existing contract-pin
test (`pins_v0_5_test_contract_maps_each_proof`) gets the v0.5.2 case names added
to its `Cases` list, so it asserts the new section exists.

**Suites.** Pure normalize proofs go in a new EUnit module
`soma_proposal_tests` in `apps/soma_actor/test/` — no actor, no processes, the
direct counterpart to `soma_tool_manifest_tests`. The actor-side proofs go in a
new Common Test suite `soma_proposal_SUITE` in `apps/soma_actor/test/`, set up
like `soma_llm_call_SUITE`: boot `soma_runtime` for the event store, start an
actor through `soma_actor_sup:start_actor/1`, drive it through the real
`soma_actor:send/2` with an `llm` envelope carrying a proposal directive.

## Acceptance criteria → tests

### Criterion 1 — valid `reply` normalizes to `{ok, Proposal}` with `kind => reply`
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1` (the whole module is the unit)
- Test: `test_reply_normalizes_ok` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 2 — valid `run_steps` whose steps pass the id+tool check normalizes ok
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1`
- Test: `test_run_steps_normalizes_ok` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 3 — valid `reject` normalizes to `{ok, Proposal}`
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1`
- Test: `test_reject_normalizes_ok` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 4 — valid `ask` normalizes to `{ok, Proposal}`
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1`
- Test: `test_ask_normalizes_ok` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 5 — unknown `kind` returns `{error, [Diagnostic]}`
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1`
- Test: `test_unknown_kind_errors` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 6 — `kind => actor_message` returns `{error, [Diagnostic]}` (deferred kind)
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1`
- Test: `test_actor_message_kind_errors` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 7 — `reply` missing `text` returns `{error, [Diagnostic]}`
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1`
- Test: `test_reply_missing_text_errors` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 8 — `run_steps` with a step failing the id+tool check returns `{error, [Diagnostic]}`
- Call chain: none (pure module, called directly)
- Test entry: `soma_proposal:normalize/1`
- Test: `test_run_steps_bad_step_errors` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 9 — after a valid `reply` proposal, `get_task_result/2` returns the normalized proposal
- Call chain: `soma_actor:send/2` → `idle({call,_},{send,_})` → `maybe_start_llm_call` → `soma_llm_call:start` → worker `perform_call` returns the raw proposal → `idle(info,{llm_result,...,{ok,Output}})` → `soma_proposal:normalize/1` → task result stored → `soma_actor:get_task_result/2`
- Test entry: `soma_actor:send/2` (no layer bypassed; drives the real actor with an `llm` envelope, then reads the result through `get_task_result/2`)
- Test: `reply_proposal_stored_as_task_result` in `apps/soma_actor/test/soma_proposal_SUITE.erl`

### Criterion 10 — after a valid `reply` proposal, the actor emits `proposal.created` carrying the task's `correlation_id`
- Call chain: `soma_actor:send/2` → … → `idle(info,{llm_result,...})` → `soma_proposal:normalize/1` `{ok,_}` → `emit(proposal.created)` → `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2` (drives the real actor, then reads the event back through `by_correlation/2`)
- Test: `reply_proposal_emits_proposal_created_with_correlation_id` in `apps/soma_actor/test/soma_proposal_SUITE.erl`

### Criterion 11 — after a valid `run_steps` proposal, the event trail has no `run.started`
- Call chain: `soma_actor:send/2` → … → `idle(info,{llm_result,...})` → `soma_proposal:normalize/1` `{ok,_}` → task result stored, no `soma_run` started → `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2` (drives the real actor, then scans the correlated events for any `run.started`)
- Test: `run_steps_proposal_starts_no_run` in `apps/soma_actor/test/soma_proposal_SUITE.erl`

### Criterion 12 — after a proposal that fails normalization, task status reads `failed`
- Call chain: `soma_actor:send/2` → … → `idle(info,{llm_result,...})` → `soma_proposal:normalize/1` `{error,_}` → task set `failed` → `soma_actor:get_task_status/2`
- Test entry: `soma_actor:send/2` (drives the real actor with a malformed-proposal directive, then reads status)
- Test: `malformed_proposal_marks_task_failed` in `apps/soma_actor/test/soma_proposal_SUITE.erl`

### Criterion 13 — after a malformed-proposal failure, the actor is alive and accepts the next `send/2`
- Call chain: `soma_actor:send/2` (malformed) → task `failed` → second `soma_actor:send/2` accepted while the same actor pid stays alive
- Test entry: `soma_actor:send/2` (two real sends to one actor; asserts the actor pid is alive and the second send returns `{ok, TaskId}`)
- Test: `actor_survives_malformed_proposal_takes_next_send` in `apps/soma_actor/test/soma_proposal_SUITE.erl`

### Criterion 14 — `by_correlation/2` returns `proposal.created` plus at least one `actor.*` and one `llm.*`
- Call chain: `soma_actor:send/2` → … → `proposal.created` emitted alongside the existing `actor.*` and `llm.*` events → `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2` (drives the real actor, then reads the correlated events and partitions by type)
- Test: `by_correlation_returns_proposal_actor_and_llm_events` in `apps/soma_actor/test/soma_proposal_SUITE.erl`

### Criterion 15 — contract doc gains a v0.5.2 section and the pin test asserts it exists
- Call chain: none (direct source-file read)
- Test entry: off chain — the test reads `docs/contracts/v0.5-test-contract.md` off disk, since it pins a documentation deliverable, not runtime behaviour
- Test: `pins_v0_5_test_contract_maps_each_proof` in `apps/soma_actor/test/soma_llm_call_SUITE.erl` (the existing pin test, with the v0.5.2 case names added to its `Cases` list)

### Criterion 16 — `rebar3 eunit && rebar3 ct` is green
- Call chain: none (the full gate)
- Test entry: off chain — this is the whole suite run, not a single test
- Test: the full `rebar3 eunit && rebar3 ct` run

## Risks & trade-offs

The step-shape rule is now stated in two places: `valid_step/1` in
`soma_actor.erl` (for envelope steps) and the same check inside `soma_proposal`
(for `run_steps` proposal steps). Sharing it would mean either the pure module
importing the actor (breaks the one-way dependency) or extracting a third helper
module for two `maps:is_key` calls. Duplicating the two-line rule is the smaller
cost; if the step-shape check grows, that calculus changes and the shared helper
becomes worth it.

Each error path returns a single-element diagnostic list, not the full set of
problems in one pass. A `run_steps` proposal with two bad steps reports the first
failure, not both. The signature already returns a list, so collecting multiple
diagnostics later is additive. For this slice the criteria only require that a
bad proposal produces a non-empty `{error, [Diagnostic]}`, so one diagnostic is
enough and avoids speculative accumulation logic.

The mock returns a raw proposal map that is already well-formed Erlang — there is
no parsing of LLM text into a map here. A real provider returns a string that
must be decoded before `normalize/1` sees it. That decode step does not exist yet
and is not in scope; `normalize/1` is deliberately the validation boundary only,
and the decode boundary lands with the real provider.
