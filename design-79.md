# v0.5.1 follow-up: emit llm.failed on LLM-worker crash

## Current state

`soma_actor` emits four of the five `llm.*` events the v0.5 contract names.
`llm.started` fires in `maybe_start_llm_call/4`, `llm.succeeded` in the
`{llm_result, _, _, {ok, _}}` info handler, `llm.timeout` in the call-timeout
handler, and `llm.cancelled` in the cancel handler. The fifth, `llm.failed`,
is never emitted.

The gap is in the `'DOWN'` backstop at `apps/soma_actor/src/soma_actor.erl`
lines 309-332. That clause handles two different deaths with one body: a
`soma_run` process that crashed without sending a terminal message, and a
`soma_llm_call` worker that crashed. Both land here through a monitor `'DOWN'`
with a non-`normal` reason. The body records the task `failed` and emits only
`actor.task.failed`. So when the `crash` mock dies, the task does reach
`failed` and the actor does survive, but no `llm.failed` event is ever written.

`docs/contracts/v0.5-test-contract.md` lines 37-38 promises all five `llm.*`
events. The doc and the code disagree — the same contract/code mismatch #73
fixed for a `run.*` event.

Crash proof 6 (`soma_llm_call_SUITE` · `crash_reaches_actor_as_failed_via_down`)
checks the task reaches `failed`, the worker is dead, and the actor is alive.
It never asserts an `llm.failed` event, so the suite stays green while the
event is missing.

## Approach

Branch the `'DOWN'` backstop on whether the dead process was an LLM worker, and
emit `llm.failed` when it was. The handler already has the signal it needs: the
task's `llm_call_id`. A task that started an LLM call carries `llm_call_id` in
its task map (set in `maybe_start_llm_call/4`); a task that started a `soma_run`
does not. `clear_llm_call/2` already keys off exactly this field to decide
whether there is LLM bookkeeping to tear down.

So in the backstop, after the existing teardown and before (or alongside)
emitting `actor.task.failed`, look up the task's `llm_call_id`. When it is
present, emit `llm.failed` carrying the task's `correlation_id` and
`llm_call_id`, matching the payload shape of the other four `llm.*` events.
When it is absent — a `soma_run` crash — emit nothing extra, so the run path
keeps emitting only `actor.task.failed`.

`actor.task.failed` stays. The LLM crash is still an actor-level task failure,
so the task-level event still fires. `llm.failed` is added on top of it for the
LLM case, the same way `llm.succeeded` sits alongside the task's
`actor.task.completed` on the success path. This keeps `llm.*` symmetric with
`run.*` and `tool.*`, which both already carry a `.failed`.

One ordering note: emit `llm.failed` before `actor.task.failed` so the event
trail reads worker-level cause first, then task-level outcome. This mirrors the
success path, where `llm.succeeded` and `actor.result.created` precede
`actor.task.completed`. The order is a readability choice, not a correctness
one — `by_correlation/2` returns both regardless.

No change to `clear_llm_call/2`, the timer logic, or the worker. The fix is one
branch inside one existing clause.

## Acceptance criteria → tests

### Criterion 1 — crash emits llm.failed with correlation_id and llm_call_id
- Call chain: `soma_actor:send/2` → `idle({call,From},{send,Envelope})` →
  `maybe_start_llm_call/4` starts the `crash` worker and monitors it → worker
  dies abnormally → actor receives `{'DOWN', MRef, process, _, Reason}` →
  backstop clause emits `llm.failed`
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `crash_reaches_actor_as_failed_via_down` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`, extended to read the
  `llm.failed` event back from the store and assert it carries the envelope's
  `correlation_id` and the task's `llm_call_id`

### Criterion 2 — by_correlation returns llm.failed beside actor.task.failed
- Call chain: same crash chain as criterion 1 → both events land in the store →
  `soma_event_store:by_correlation/2` for the task's correlation id
- Test entry: `soma_actor:send/2`, then a direct
  `soma_event_store:by_correlation/2` read
- Test: `crash_reaches_actor_as_failed_via_down` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl` — the same extension asserts
  the `by_correlation/2` result holds both an `llm.failed` event and an
  `actor.task.failed` event under the one correlation id

### Criterion 3 — a soma_run crash still emits actor.task.failed and no llm.failed
- Call chain: `soma_actor:send/2` with a valid steps envelope →
  `maybe_start_run/4` starts and monitors a `soma_run` → the run pid is killed
  abnormally mid-execution → actor receives `{'DOWN', ...}` → backstop clause
  emits `actor.task.failed` only
- Test entry: `soma_actor:send/2`, then `exit(RunPid, kill)` to drive the
  process-crash backstop the same way the existing case does
- Test: `run_death_after_validation_records_failed` in
  `apps/soma_actor/test/soma_actor_validation_SUITE.erl`, extended to assert the
  store holds an `actor.task.failed` event for the task and zero `llm.failed`
  events

### Criterion 4 — task reaches failed, actor alive, actor pid distinct from worker
- Call chain: same crash chain as criterion 1
- Test entry: `soma_actor:send/2`
- Test: `crash_reaches_actor_as_failed_via_down` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl` — these assertions already
  exist in the case and stay (task `failed`, worker dead, actor alive, actor
  pid not equal to worker pid)

### Criterion 5 — a parked ask on the crashing call still gets {error, Reason}
- Call chain: `soma_actor:ask/3` with the `crash` llm envelope → the caller
  parks as a waiter against the task → worker dies → backstop clause records
  `failed`, emits `llm.failed`, and calls `reply_waiter/3` with
  `{error, Reason}`
- Test entry: `soma_actor:ask/3` (the call blocks until the backstop replies)
- Test: `ask_on_crashing_llm_call_gets_error` (new case) in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`, asserting the `ask/3` return
  is `{error, Reason}` and the actor stays alive

### Criterion 6 — contract doc maps the llm.failed-on-crash assertion
- Call chain: none (direct source-file read)
- Test entry: off chain — the pin reads the doc file, it is a documentation
  deliverable, not runtime behaviour
- Test: `pins_v0_5_test_contract_maps_each_proof` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`. Proof 6's row in
  `docs/contracts/v0.5-test-contract.md` is extended to state the `llm.failed`
  assertion under the existing case name `crash_reaches_actor_as_failed_via_down`.
  The new `ask_on_crashing_llm_call_gets_error` case is added to the contract
  doc and to the pin's own `Cases` list (the note in the issue), so the pin
  keeps matching the suite.

### Criterion 7 — rebar3 eunit && rebar3 ct green at HEAD
- Call chain: none (whole-suite run)
- Test entry: the merge gate
- Test: the full `rebar3 eunit && rebar3 ct` run, with the extended and new
  cases above passing

## Risks & trade-offs

Emitting two events for one LLM crash (`llm.failed` then `actor.task.failed`)
means a consumer counting task failures by event must not double-count across
the two families. That is already true today for the success path
(`llm.succeeded` plus `actor.task.completed`), so this only extends the existing
shape to the failure path. It is the price of keeping `llm.*` a complete family
rather than collapsing the crash case into the task-level event.

The branch reads `llm_call_id` from the task map after `clear_llm_call/2` has
run. `clear_llm_call/2` removes the `llm_calls` registry entry but does not
strip `llm_call_id` from the task map, so the value is still readable where the
emit needs it. The design depends on that — if a later change starts wiping the
task field during teardown, the emit would lose its `llm_call_id`. The test
asserts the event carries a non-`undefined` `llm_call_id`, so that regression
would be caught.

Extending proof 6 in place (rather than adding a separate crash-emits-event
proof row) keeps the case name `crash_reaches_actor_as_failed_via_down` stable,
so the pin's `Cases` list needs no churn for that case. Only the new `ask` case
adds a name to both the doc and the pin list.
