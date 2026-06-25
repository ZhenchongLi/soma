# v0.5.1: soma_llm_call — supervised, monitored LLM-call worker + mock provider

## Current state

`soma_actor` (a `gen_statem` in `apps/soma_actor/src/soma_actor.erl`) already
owns one kind of child: a `soma_run`. When an envelope carries a `steps` list,
`maybe_start_run/4` starts a run under `soma_run_sup`, monitors the run pid,
tracks `run_id => task_id`, and records the task as `running`. The run reports
its outcome back as one of `{run_completed | run_failed | run_timeout |
run_cancelled, RunId, ...}`, and the actor turns that into task data plus
`actor.*` events. A run pid that dies without sending a terminal message arrives
as a monitor `'DOWN'` and is recorded as a terminal `failed` task. The normal
terminal messages demonitor-and-flush their ref so a still-alive run leaves no
dangling monitor.

There is no LLM path. An envelope with no `steps` is accepted and starts
nothing. The actor has never spawned a `soma_llm_call` worker, that module does
not exist, and no `llm.*` event name is emitted anywhere. The v0.4 contract
already locked the decision that the actor spawns and monitors this worker
directly with no `soma_llm_call_sup`, mirroring `soma_run → soma_tool_call`, but
the worker itself is unbuilt.

The runtime forbids a hard dependency on a real LLM. So the call mechanics have
to be provable without a network or a model.

## Approach

Add a disposable worker `soma_llm_call` in `apps/soma_runtime/src/`, shaped like
`soma_tool_call`: it runs in its own process, does one call, sends a result
message back to its owner, then exits. The actor owns it directly, exactly as it
owns a run.

The trigger is an envelope `llm` field, a map, parallel to `steps`. Fixed-rule
dispatch in the actor:

- `steps` (list) present → start a `soma_run` (unchanged).
- `llm` (map) present → start a `soma_llm_call`.
- neither → `accepted`, no action (unchanged).

An envelope carrying both `steps` and `llm` is malformed. It is rejected up
front with `{error, _}` before anything starts, the same up-front-validation
discipline `validate_envelope/1` already uses for malformed step lists. This
rejection happens in `validate_envelope/1` (or a helper it calls), so a bad
envelope never reaches `maybe_start_run` or a new `maybe_start_llm_call`.

The mock is the thinnest thing that works. `soma_llm_call` reads a directive out
of the `llm` map and acts on it directly: `success` returns the configured
output, `slow` runs past the call timeout, `crash` dies abnormally, `hang`
blocks until cancelled. There is no provider behaviour, no `mock` module, no
provider type. The one rule that buys the future: the actual call lives in a
single function `perform_call/1` so that when a real provider lands, that one
point grows the provider seam. Mock logic does not get scattered across the
worker.

The worker reports back with messages parallel to the run's, keyed by an
`llm_call_id` the actor mints:

- `{llm_result, LlmCallId, self(), {ok, Output}}` on success.
- `{llm_result, LlmCallId, self(), {error, Reason}}` on a returned error.
- a crash arrives as the monitor `'DOWN'` (no result message).

The actor handles these the way it handles run messages. It mints an
`llm_call_id`, monitors the worker pid, tracks `llm_call_id => task_id`, records
the task `running`, and arms a call-timeout timer. The timeout and cancel paths
kill the worker (`exit(WorkerPid, kill)`) and record `timeout` / `cancelled` —
the actor does the kill itself here because, unlike a `soma_run`, the worker is
not a `gen_statem` that can drive its own teardown. The worker holds no external
OS process (mock only, no port), so there is nothing to reap beyond the BEAM
pid. A successful or errored result demonitors-and-flushes the worker ref.

Timeout placement: the actor arms a timer when it starts the call and treats the
timer firing as the timeout, rather than asking the worker to time itself out. A
`slow` mock that ignores the timer is exactly the case this proves — the owner,
not the worker, enforces the bound. This mirrors how `soma_run` arms the
per-step `state_timeout` rather than trusting the tool to stop itself.

Events mirror `tool.*` / `run.*`: `llm.started`, `llm.succeeded`, `llm.failed`,
`llm.timeout`, `llm.cancelled`. Success uses `succeeded` like the one-shot
`tool.*`; the stop paths use `timeout` / `cancelled` like `run.*`. Every
`llm.*` event carries the task's `correlation_id`, so `by_correlation/2` returns
them alongside the task's `actor.*` events. The actor already threads
`correlation_id` through every task; the new emit path stamps it the same way
`emit/3` does today.

Where the `llm.*` events are emitted is a real choice. The worker has no event
store handle today and the actor already emits every `actor.*` event. Emitting
`llm.*` from the actor keeps the event store out of the worker and keeps the
worker as thin as the mock decision asks. `llm.started` is emitted when the
actor starts the call; `llm.succeeded` / `llm.failed` / `llm.timeout` /
`llm.cancelled` when the actor handles the terminal outcome. The worker stays a
pure compute-and-reply process. (If a later slice needs the worker to emit, that
is a seam to grow then, not now.)

## Acceptance criteria → tests

Suite for the actor-facing proofs: a new `soma_llm_call_SUITE` in
`apps/soma_actor/test/`, set up like `soma_actor_SUITE` (start the
`soma_runtime` app, start an event store, start an actor through
`soma_actor_sup:start_actor/1`). The worker-only proof that touches no actor
goes in an EUnit module `soma_llm_call_tests` in `apps/soma_runtime/test/`.

### Criterion 1 — mock returns configured output, makes no network call
- Call chain: none (direct worker call). The worker's `perform_call/1` is
  driven from a test with a `success` directive; there is no socket open in the
  module to make a network call possible.
- Test entry: `soma_llm_call:perform_call/1` (or `start/1` plus a receive of the
  `llm_result` message) directly, no actor in the path. The "no network call" half
  is a source-level fact — the module opens no socket and links no network library
  — asserted by the absence in the worker, not by a runtime probe.
- Test: `test_mock_success_returns_configured_output` in
  `apps/soma_runtime/test/soma_llm_call_tests.erl`

### Criterion 2 — worker runs in a pid distinct from the actor pid
- Call chain: caller → `soma_actor:send/2` → `idle/3` `{send, Envelope}` →
  `maybe_start_llm_call` → `soma_llm_call:start/1`
- Test entry: `soma_actor:send/2` with an `llm` envelope. The test reads the
  `llm.started` event's worker pid (or the worker pid recorded on the task) and
  asserts it is not the actor pid.
- Test: `llm_worker_runs_in_distinct_pid` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 3 — `get_task_result` returns the call's output after success
- Call chain: `soma_actor:send/2` → `maybe_start_llm_call` →
  `soma_llm_call` success → `{llm_result, ...}` back to `idle/3` →
  `soma_actor:get_task_result/2`
- Test entry: `soma_actor:send/2` to start the call, then
  `soma_actor:get_task_result/2` after the success message lands.
- Test: `get_task_result_holds_llm_output` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 4 — timeout leaves worker dead, task `timeout`, actor alive
- Call chain: `soma_actor:send/2` → `maybe_start_llm_call` (arms the
  call-timeout timer) → `soma_llm_call` `slow` ignores the timer → actor's
  timeout handler kills the worker
- Test entry: `soma_actor:send/2` with a `slow` directive and a short call
  timeout. The test asserts the worker pid is dead (`is_process_alive` false),
  `get_task_status` reads `timeout`, and the actor pid is still alive.
- Test: `slow_call_times_out_worker_dead_actor_alive` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 5 — cancel leaves worker dead, task `cancelled`, actor alive
- Call chain: `soma_actor:send/2` (starts a `hang` call) →
  `soma_actor:cancel/2` → `idle/3` `{cancel, TaskId}` → kills the worker
- Test entry: `soma_actor:send/2` to start a `hang` call, then
  `soma_actor:cancel/2`. The test asserts the worker pid is dead,
  `get_task_status` reads `cancelled`, and the actor pid is still alive.
- Test: `cancel_in_flight_call_worker_dead_actor_alive` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 6 — crash reaches actor via `'DOWN'`, task `failed`, actor alive
- Call chain: `soma_actor:send/2` (starts a `crash` call) → `soma_llm_call`
  dies abnormally → monitor `'DOWN'` to `idle/3`
- Test entry: `soma_actor:send/2` with a `crash` directive. The test asserts the
  task reaches `failed`, the actor pid is alive, and the actor pid is not the
  (now dead) worker pid.
- Test: `crash_reaches_actor_as_failed_via_down` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 7 — actor stays responsive while a call is in flight
- Call chain: `soma_actor:send/2` (starts a `hang` call) →
  `soma_actor:get_task_status/2` while the call is still running
- Test entry: `soma_actor:get_task_status/2` mid-flight. The test asserts the
  status returns promptly with a non-terminal value (`running`), proving the
  actor is not blocked on the worker.
- Test: `status_promptly_while_llm_call_in_flight` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 8 — a completed call appends an `llm.*` event with `correlation_id`
- Call chain: `soma_actor:send/2` → call succeeds → actor emits `llm.succeeded`
  → `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2` with a `correlation_id` in the envelope, then
  `soma_event_store:by_correlation/2`. The test asserts at least one `llm.*`
  event is present and carries that `correlation_id`.
- Test: `completed_call_appends_llm_event_with_correlation_id` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 9 — `by_correlation/2` returns `llm.*` alongside `actor.*`
- Call chain: `soma_actor:send/2` → call succeeds (actor emits both `actor.*`
  and `llm.*` for the task) → `soma_event_store:by_correlation/2`
- Test entry: `soma_event_store:by_correlation/2` for the task's
  `correlation_id`. The test asserts the returned list holds both `actor.*` and
  `llm.*` event types for the one id.
- Test: `by_correlation_returns_llm_and_actor_events` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 10 — the v0.5 test contract document exists and maps each proof
- Call chain: none (direct source-file read)
- Test entry: off the call chain — this is a documentation deliverable, not
  runtime behavior. The proof is that `docs/contracts/v0.5-test-contract.md`
  exists and names, for each process proof in this slice, the suite and case
  that proves it.
- Test: `pins_v0_5_test_contract_maps_each_proof` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl` (reads the file, asserts it
  exists and references each suite + case named above) — mirroring how earlier
  slices pinned their contract docs.

### Bonus coverage — both `steps` and `llm` is rejected up front
This is the decision-1 mutual-exclusion rule. It is not a numbered criterion but
is load-bearing for the dispatch design, so it gets its own case.
- Call chain: `soma_actor:send/2` → `validate_envelope/1`
- Test entry: `soma_actor:send/2` with an envelope carrying both fields; asserts
  `{error, _}` and that no run and no llm call started, actor pid alive.
- Test: `both_steps_and_llm_rejected_no_child_started` in
  `apps/soma_actor/test/soma_llm_call_SUITE.erl`

## Risks & trade-offs

Emitting `llm.*` from the actor, not the worker, means the worker stays
event-store-free but the actor now owns one more emit path. When a real provider
arrives and a streaming or multi-step call wants to emit its own progress
events, that emit point has to move into the worker, which is a real refactor,
not a no-op. The trade is deliberate: keeping the worker thin matches the
mock-only decision, and there is nothing mid-call to emit yet.

The actor kills the LLM worker itself on timeout and cancel, whereas for a run
it sends `cancel` and lets the `soma_run` `gen_statem` drive its own teardown.
That is an asymmetry in the actor's two child paths. It is justified: the worker
is a bare disposable process with no state machine to receive a `cancel`
message, so `exit(WorkerPid, kill)` is the honest teardown — the same brutal kill
`soma_run` uses on `soma_tool_call`. The cost is that a reader has to notice the
two child kinds tear down differently.

The `llm` envelope field is transitional scaffolding. In v0.5.4 the actor will
decide internally to call the LLM, so `llm` stops being a caller-supplied field.
Tests written against a caller-supplied `llm` field will need rework then. That
is accepted: this slice proves process mechanics, and a caller-supplied trigger
is the only way to drive them before the decision loop exists.
