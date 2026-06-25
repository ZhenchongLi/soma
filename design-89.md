# v0.5.5: budget & loop limits — exhaustion fails the task, not the actor

## Current state

The actor decides and executes today. An `llm` envelope starts a `soma_llm_call`
worker (`maybe_start_llm_call/4` in `soma_actor.erl`), the worker returns a
proposal, `soma_proposal:normalize/1` validates it, `soma_policy:check/2` votes
allow or reject, and an approved `run_steps` proposal starts a run through
`start_owned_run/4`. A direct `steps` envelope skips the whole decision loop and
goes straight to a run (`maybe_start_run/4`).

There is no limit on any of this. An actor will start an LLM call for every
`llm` envelope it accepts, and it will execute an approved `run_steps` proposal
no matter how many steps it carries. Once the decision loop becomes multi-turn
(a later slice), an unbounded actor could spin LLM calls forever on one task.
Even now, a proposal carrying a huge step list executes with no ceiling.

The `#data` record carries `actor_id`, `model_config`, `tool_policy`,
`event_store`, and the per-task bookkeeping maps. It has no budget field and no
per-task call accounting. `soma_actor_sup:start_actor/1` passes an opts map with
`actor_id`, `model_config`, `tool_policy`, and `event_store` straight into
`init/1`; there is no `budget` key.

The terminal-failure-as-data path already exists from #73/#79. A failed task
records `status => failed` with a `reason`, emits `actor.task.failed` carrying
that reason, and releases any parked `ask` waiter with `{error, Reason}`. The
invalid-proposal branch and the `'DOWN'` backstop both use it. The actor stays
alive through all of it.

The v0.4 contract deferred P13 ("budget exhaustion fails the task, not the
actor") because there was no budget accounting to gate against. This slice
delivers it.

## Approach

Add two budget checks, one at each of the actor's two spend points. Reuse the
existing failure path for both — a budget failure is just another reason a task
fails as data, so no new failure machinery.

The budget is one opts field, `budget`, a map that may carry `max_llm_calls`
and `max_steps`. It defaults to unlimited: an absent key means no cap on that
dimension, and an absent `budget` field means no caps at all. `init/1` reads it
into the `#data` record. The record also gains per-task LLM-call accounting — a
count of how many LLM calls each task has started.

**Spend point one — before an LLM call.** `maybe_start_llm_call/4` checks the
task's LLM-call count against `max_llm_calls` before it starts the worker. If
the count is already at the cap, it makes no call: it fails the task with reason
`{budget_exceeded, max_llm_calls}` through the shared failure path, emits no
`llm.started`, and returns. With today's single-shot flow, `max_llm_calls => 0`
fails the first call and `max_llm_calls => 1` (or unlimited) lets it through, so
the cap is degenerate now and becomes a real loop limit when iteration lands.
The count increments only when a call actually starts.

**Spend point two — before executing an approved `run_steps` proposal.** The
`{proposal, Proposal}` handler, in its `run_steps` branch right after
`proposal.approved` and `proposal.executed` are decided, checks the proposal's
step count against `max_steps`. If the count exceeds `max_steps`, it starts no
run: it fails the task with reason `{budget_exceeded, max_steps}` through the
shared failure path and emits no `run.started`. The check sits before the
`emit "proposal.executed"` and `start_owned_run/4` calls, so a budget-failed
proposal emits neither. A within-budget proposal runs unchanged.

The direct `steps` envelope path is **not** gated by `max_steps`. The budget is
framed around the decision loop's spend points, and the direct path is the v0.4
escape hatch with no proposal. This matches the issue's open question — the
direct path is read as out of scope for this slice. If it should be capped, that
is its own future criterion.

**The shared failure helper.** Extract the existing failure shape — set
`status => failed` with the reason, emit `actor.task.failed` carrying the
reason, release any parked waiter with `{error, Reason}` — into one helper, and
call it from both budget checks. This is the same shape the invalid-proposal
branch already writes inline; the budget checks reuse it rather than duplicating
it.

The default-unchanged criterion falls out for free: with no `budget` field, both
checks see an unlimited cap and take the existing path, so a no-budget actor
behaves exactly as it did in v0.5.4.

## Acceptance criteria → tests

The actor-side proofs go in a new Common Test suite `soma_actor_budget_SUITE` in
`apps/soma_actor/test/`, set up like `soma_proposal_exec_SUITE`: boot
`soma_runtime` so `soma_run_sup` and the event store are alive, start an actor
through `soma_actor_sup:start_actor/1` with a `budget` (and a `tool_policy`
where a proposal is involved), drive it through the real `soma_actor:send/2` /
`ask/3`, and read outcomes back through `get_task_status/2`,
`get_task_result/2`, and `soma_event_store:by_correlation/2`.

### Criterion 1 — `max_llm_calls => 0` fails the llm task with `{budget_exceeded, max_llm_calls}`
- Call chain: `soma_actor:send/2` → `idle({call, _}, {send, Envelope})` → `maybe_start_llm_call/4` → budget check fails → shared failure helper → `get_task_status/2` reads the reason
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `budget_zero_llm_calls_fails_task_with_reason` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 2 — that same case records no `llm.started`
- Call chain: same as criterion 1; the budget check returns before the `emit "llm.started"` call, so the trail carries none
- Test entry: `soma_actor:send/2`; the assertion reads the event trail through `soma_event_store:by_correlation/2` and asserts no `llm.started`
- Test: `budget_zero_llm_calls_emits_no_llm_started` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 3 — `max_steps => N` fails an approved over-N-step proposal with `{budget_exceeded, max_steps}`
- Call chain: `soma_actor:send/2` → `idle({call, _}, {send, Envelope})` → `maybe_start_llm_call/4` (call allowed) → worker returns proposal → `idle(info, {llm_result, ...})` → `proposal_result/1` → `soma_policy:check/2` allow → `run_steps` branch → step-count check exceeds `max_steps` → shared failure helper → `get_task_status/2` reads the reason
- Test entry: `soma_actor:send/2` (no layer bypassed; the proposal arrives through the real mock worker)
- Test: `budget_max_steps_fails_oversized_proposal_with_reason` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 4 — that same case records no `run.started`
- Call chain: same as criterion 3; the step-count check returns before `emit "proposal.executed"` and `start_owned_run/4`, so no run starts and the trail carries no `run.started`
- Test entry: `soma_actor:send/2`; the assertion reads the trail through `soma_event_store:by_correlation/2` and asserts no `run.started`
- Test: `budget_max_steps_oversized_proposal_emits_no_run_started` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 5 — a within-`max_steps` approved proposal still reaches `completed`
- Call chain: `soma_actor:send/2` → `maybe_start_llm_call/4` → worker → `idle(info, {llm_result, ...})` → `soma_policy:check/2` allow → `run_steps` branch → step-count within cap → `start_owned_run/4` → run completes → `idle(info, {run_completed, ...})` → `get_task_status/2` reads `completed`
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `budget_within_max_steps_proposal_completes` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 6 — a budget-failed task reads `failed` through `get_task_status/2`
- Call chain: a budget failure (the `max_llm_calls` case) → shared failure helper sets `status => failed` → `soma_actor:get_task_status/2` → `idle({call, _}, {get_task_status, TaskId})`
- Test entry: `soma_actor:get_task_status/2` (no layer bypassed)
- Test: `budget_failed_task_status_reads_failed` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 7 — after a budget failure the same actor drives a later within-budget envelope to `completed`
- Call chain: first `send/2` budget-fails → actor stays in `idle` → second `send/2` with a within-budget `llm` envelope → full decision loop → run completes → `idle(info, {run_completed, ...})` → `get_task_status/2` reads `completed` on the second task
- Test entry: `soma_actor:send/2` twice on one actor pid (no layer bypassed); also asserts the actor pid is alive after the failure
- Test: `actor_survives_budget_failure_takes_next_envelope` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 8 — a parked `ask` on a budget-failed task gets `{error, _}`
- Call chain: `soma_actor:ask/3` → `idle({call, From}, {ask, Envelope})` → for an `llm` envelope, `maybe_start_llm_call/4` runs and the budget check fails inside it → shared failure helper releases the parked waiter `From` with `{error, {budget_exceeded, max_llm_calls}}`
- Test entry: `soma_actor:ask/3` (no layer bypassed). Note: the `ask` handler parks a waiter only when the envelope carries `steps`; for an `llm` envelope the shared failure helper must release `From`, so this proof also pins that the helper releases the waiter on the `llm`-budget path
- Test: `parked_ask_on_budget_failed_task_gets_error` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 9 — `by_correlation/2` surfaces the budget task's `actor.task.failed` carrying the reason
- Call chain: a budget failure → shared failure helper → `emit "actor.task.failed"` with the budget reason → `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2` to drive the failure, then `soma_event_store:by_correlation/2` to read the trail
- Test: `by_correlation_surfaces_budget_failed_event_with_reason` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 10 — a no-`budget` actor still executes an approved `run_steps` proposal to `completed`
- Call chain: `soma_actor:send/2` with no `budget` opt → `maybe_start_llm_call/4` (unlimited) → worker → allow → `run_steps` branch (unlimited `max_steps`) → `start_owned_run/4` → run completes → `get_task_status/2` reads `completed`
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `no_budget_field_executes_approved_run_steps_to_completed` in `apps/soma_actor/test/soma_actor_budget_SUITE.erl`

### Criterion 11 — the contract doc gains a v0.5.5 section and the pin test names the new suite and cases
- Call chain: none (direct source-file read). The pin test reads `docs/contracts/v0.5-test-contract.md` and asserts it names the suite and every case
- Test entry: `pins_v0_5_test_contract_maps_each_proof` in `soma_llm_call_SUITE` reads the doc file directly; off the actor call chain because it is a doc-shape assertion, not an actor behaviour
- Test: extend `pins_v0_5_test_contract_maps_each_proof` in `apps/soma_actor/test/soma_llm_call_SUITE.erl` to assert `<<"v0.5.5">>`, `<<"soma_actor_budget_SUITE">>`, and each new case name; add the v0.5.5 section to `docs/contracts/v0.5-test-contract.md`

### Criterion 12 — `rebar3 eunit && rebar3 ct` is green
- Call chain: none (build/gate assertion)
- Test entry: the merge gate runs both commands
- Test: the whole suite set above, plus the existing suites, pass under `rebar3 eunit && rebar3 ct`

## Risks & trade-offs

The `max_llm_calls` cap is degenerate today. With single-shot flow, only `0`
versus `>= 1` is observable, so criterion 1 tests a cap that does real work only
once iteration lands. This is intended — the issue calls it forward-looking —
but it means the test pins a smaller behaviour than the field name suggests. The
test asserts what is true now: count reaches the cap, call is refused.

Leaving the direct `steps` path uncapped is a real gap, not an oversight. A
caller who wants a step ceiling but sends a direct `steps` envelope gets none.
This matches the issue's framing (budget guards the decision loop's spend
points), and the open question already flags it. If the direct path needs a cap,
it is a separate criterion in a later slice.

The per-task LLM-call count lives in the actor's `#data` and is never reaped for
finished tasks, same as the existing `tasks` map. For a long-lived actor taking
many tasks this is unbounded memory growth. It is the pre-existing pattern in
this module, not something this slice introduces, so it is out of scope here —
worth noting for a future durability slice.
