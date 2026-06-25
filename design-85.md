# [cc] v0.5.3: policy gate — proposals get an allow/reject verdict, no execution

## Current state

v0.5.2 gave the LLM's output a shape. When a mock call returns a map with a
`kind` tag, `soma_actor` runs it through `soma_proposal:normalize/1`. A valid
proposal becomes the task result and the actor emits `proposal.created`. This
all happens in one place: the `idle(info, {llm_result, ...}, ...)` clause in
`soma_actor.erl` (lines 258–311), in the `{proposal, Proposal}` branch around
line 287.

What that branch does today, after emitting `proposal.created`: it records the
task `completed` and replies to any waiter with `{ok, Proposal}`. There is no
check on the proposal. A `run_steps` proposal naming any tool at all is recorded
and the task reads `completed` — even though the actor already holds a
`tool_policy` field (`soma_actor.erl:76`, set from `start_actor/1` opts) that
nothing reads.

So the gap is: a proposal is data, but no verdict is data. The actor carries a
policy it never applies, and `completed` is the same status whether the proposal
named an allowed tool or a forbidden one. There is no `proposal.approved` or
`proposal.rejected` event, and no task status that says "passed the policy but
not yet run".

## Approach

Add a pure `soma_policy` module next to `soma_proposal`, same shape: no
processes, no events, no execution. Its one entry point is

```
soma_policy:check(Proposal, Policy) -> allow | {reject, Reason}
```

The policy is a tool-name allowlist: `#{allowed_tools => [atom()] | all}`. A
`run_steps` proposal is allowed when every step's `tool` is in the allowlist.
`all`, or a policy with no `allowed_tools` key, allows any tool. `reply`,
`reject`, and `ask` proposals carry no tool, so they are allowed without an
allowlist check — only `run_steps` is gated.

The actor wires the gate into the existing `{proposal, Proposal}` branch, right
after it emits `proposal.created`. It calls `soma_policy:check(Proposal,
Data#data.tool_policy)` and records the verdict as an event:

- `allow` → emit `proposal.approved`, set task status `approved`, reply
  `{ok, Proposal}` to any waiter.
- `{reject, Reason}` → emit `proposal.rejected` carrying `reason`, set task
  status `rejected`, reply `{error, {rejected, Reason}}` (or similar) to any
  waiter.

Both verdict events carry the task's `correlation_id` (and `llm_call_id`, like
`proposal.created`), so `by_correlation/2` surfaces the verdict beside
`proposal.created`, `actor.*`, and `llm.*`. Neither path starts a `soma_run` —
that is v0.5.4.

Two new task-status values, `approved` and `rejected`, replace the old
`completed` for a gated proposal. `approved` is honest that the proposal passed
policy but has not run. `rejected` is terminal. The `opaque` and
`invalid_proposal` branches keep their current `completed` / `failed` statuses
untouched — only the valid-proposal branch changes.

One detail the tests must pin down: the allowlist holds atoms, but a proposal's
step `tool` can arrive as a binary or an atom depending on the caller (the
v0.5.2 EUnit uses `tool => echo`, the SUITE uses `tool => <<"echo">>`). The
membership check has to compare like with like. The chosen reading: the
allowlist is atoms and `soma_policy` compares a step tool against it by value,
so a test that wants a match supplies the tool in the same form the allowlist
uses. This keeps `soma_policy` from guessing at conversions. The risk note below
calls this out.

## Acceptance criteria → tests

The pure `soma_policy:check/2` criteria are unit-tested in a new EUnit module
`soma_policy_tests` in `apps/soma_actor/test/`, mirroring `soma_proposal_tests`.
They take no actor and read no events.

### Criterion 1 — allow when every step tool is in the allowlist
- Call chain: none (pure function call)
- Test entry: `soma_policy:check/2` called directly
- Test: `test_run_steps_all_tools_allowed_returns_allow` in `apps/soma_actor/test/soma_policy_tests.erl`

### Criterion 2 — reject when a step names a tool absent from the allowlist
- Call chain: none (pure function call)
- Test entry: `soma_policy:check/2` called directly
- Test: `test_run_steps_unknown_tool_returns_reject` in `apps/soma_actor/test/soma_policy_tests.erl`

### Criterion 3 — allow under `allowed_tools => all` or an absent key
- Call chain: none (pure function call)
- Test entry: `soma_policy:check/2` called directly, once with `#{allowed_tools => all}` and once with `#{}`
- Test: `test_run_steps_all_or_absent_allowlist_returns_allow` in `apps/soma_actor/test/soma_policy_tests.erl`

### Criterion 4 — allow a reply, a reject, and an ask (no tool named)
- Call chain: none (pure function call)
- Test entry: `soma_policy:check/2` called directly with each of the three tool-less kinds
- Test: `test_toolless_kinds_return_allow` in `apps/soma_actor/test/soma_policy_tests.erl`

The actor-side criteria are Common Test cases in a new suite
`soma_policy_SUITE` in `apps/soma_actor/test/`, set up like
`soma_proposal_SUITE`: boot `soma_runtime`, start an actor through
`soma_actor_sup:start_actor/1` with a `tool_policy`, drive it through the real
`soma_actor:send/2` with a `proposal` llm directive. The actor's policy is set
from the `tool_policy` opt, so each case picks the allowlist that makes its
proposal allowed or rejected.

### Criterion 5 — an allowed run_steps proposal emits `proposal.approved` with correlation_id
- Call chain: `soma_actor:send/2` → `idle({call,_},{send,_},_)` → `maybe_start_llm_call` → worker → `idle(info,{llm_result,...},_)` → `proposal_result` → `soma_policy:check/2` → `emit(proposal.approved)`
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `allowed_run_steps_emits_proposal_approved_with_correlation_id` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 6 — an allowed proposal starts no run
- Call chain: same as criterion 5, then `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2`; the no-run assertion reads back through `by_correlation/2` and finds no `run.started`
- Test: `allowed_proposal_starts_no_run` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 7 — an allowed proposal leaves task status `approved`
- Call chain: same as criterion 5, then `soma_actor:get_task_status/2`
- Test entry: `soma_actor:send/2`; status read through `get_task_status/2`
- Test: `allowed_proposal_status_reads_approved` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 8 — a rejected proposal emits `proposal.rejected` with the reason and correlation_id
- Call chain: `soma_actor:send/2` → ... → `soma_policy:check/2` returns `{reject, Reason}` → `emit(proposal.rejected)`
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `rejected_proposal_emits_proposal_rejected_with_reason_and_correlation_id` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 9 — a rejected proposal starts no run
- Call chain: same as criterion 8, then `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2`; the no-run assertion reads back through `by_correlation/2` and finds no `run.started`
- Test: `rejected_proposal_starts_no_run` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 10 — a rejected proposal leaves task status `rejected`
- Call chain: same as criterion 8, then `soma_actor:get_task_status/2`
- Test entry: `soma_actor:send/2`; status read through `get_task_status/2`
- Test: `rejected_proposal_status_reads_rejected` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 11 — actor survives a rejected proposal and takes a second send
- Call chain: `soma_actor:send/2` (rejected) → wait `rejected` → `soma_actor:send/2` (second) → wait terminal
- Test entry: `soma_actor:send/2`; asserts the actor pid is alive and the second send completes
- Test: `actor_survives_rejected_proposal_takes_next_send` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 12 — `by_correlation/2` surfaces the verdict alongside created, actor, and llm events
- Call chain: `soma_actor:send/2` → ... → verdict emitted, then `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2`; the trail is read back through `by_correlation/2` and partitioned by event type
- Test: `by_correlation_returns_verdict_created_actor_and_llm_events` in `apps/soma_actor/test/soma_policy_SUITE.erl`

### Criterion 13 — the v0.5-test-contract doc gains a v0.5.3 section and the pin asserts it
- Call chain: none (direct source-file read)
- Test entry: the existing `pins_v0_5_test_contract_maps_each_proof` case reads `docs/contracts/v0.5-test-contract.md` off the call chain — a documentation deliverable, not runtime behaviour
- Test: `pins_v0_5_test_contract_maps_each_proof` in `apps/soma_actor/test/soma_llm_call_SUITE.erl`, extended to assert the `v0.5.3` section, `soma_policy_tests`, `soma_policy_SUITE`, and every case named above are present

### Criterion 14 — `rebar3 eunit && rebar3 ct` is green
- Call chain: none (whole-suite gate)
- Test entry: the merge gate runs both
- Test: the full EUnit + CT run, no single case

## Risks & trade-offs

- **Tool-type mismatch is real.** The allowlist holds atoms but a step `tool`
  can be a binary. `soma_policy` does a value comparison and does not normalize
  binary-vs-atom. A caller whose proposal uses binary tool names and whose
  policy uses atoms will see every tool as not-allowed, so a `run_steps`
  proposal rejects when the author meant to allow it. The tests pin both sides
  to the same form to make the behaviour explicit. If v0.5.4 finds real LLM
  output always arrives as binaries, the conversion belongs in `soma_proposal`
  (one normalization point), not smeared across `soma_policy`. Flagged so the
  next slice does not rediscover it.

- **The pin test lives in another slice's suite.** Criterion 13 extends
  `soma_llm_call_SUITE`'s pin case rather than adding a fresh pin. That keeps a
  single doc-pin case but means the v0.5.1 suite grows knowledge of v0.5.3
  cases. This follows the precedent v0.5.2 already set (it added its cases to
  the same pin), so the cost is paying down later as one consolidation, not now.

- **`approved` is a non-terminal status with no follow-up yet.** Until v0.5.4
  wires approved → execute, an `approved` task sits there forever. That is the
  intended honest state for this slice, not a leak — but a reader polling
  `get_task_status/2` for a terminal value on an approved task will wait
  forever. v0.5.4 closes this; this slice deliberately leaves it open.
