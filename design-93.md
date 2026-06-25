# v0.6.1: trace tooling — render a correlation_id chain as a readable timeline

## Current state

The event store keeps every event in memory and can pull the events of one
`correlation_id` with `soma_event_store:by_correlation/2`
(`apps/soma_event_store/src/soma_event_store.erl`). That call returns a plain
list of event maps in append order. There is no helper that turns that list into
something a person can read — today you get raw maps and have to eyeball them.

The events come from two emitters with different shapes:

- `soma_run:emit/3` (`apps/soma_runtime/src/soma_run.erl`) stamps `correlation_id`
  on `run.*`, `step.*`, and `tool.*` events. On `run.failed` / `step.failed` /
  `tool.failed` the failure reason lives inside the event's `payload` map, as
  `#{reason => Reason}`.
- `soma_actor:emit/3` (`apps/soma_actor/src/soma_actor.erl`) emits `actor.*`,
  `llm.*`, and `proposal.*` events. On `actor.task.failed` the `reason` is a
  top-level key on the event, not inside `payload`.

So a reader of one correlation chain has to know that the reason sometimes sits
at top level and sometimes one level down. That is the gap this slice fills.

Timestamps: neither emitter sets `timestamp`. The store's `normalize/1` fills it
in with `erlang:system_time(nanosecond)` at append time, so every stored event
carries a numeric `timestamp`. Append order and timestamp order line up in
practice, but the criteria require ordering by `timestamp` explicitly, so the
renderer sorts on that key rather than trusting list order.

## Approach

Add one new module, `soma_trace`, in the event-store app
(`apps/soma_event_store/src/soma_trace.erl`). Read-only. It imports nothing above
`soma_event_store` — no `soma_actor`, no `soma_runtime`. Two functions:

- `timeline(Events) -> iodata()` is pure. It sorts the input list by each event's
  `timestamp` ascending, then renders one line per event. Each line names the
  `event_type` and appends whichever of the salient ids the event actually
  carries — `task_id`, `step_id`, and so on. A field absent from the event (stored
  as `undefined` or missing) is left off the line rather than printed as an empty
  placeholder. For a failure event the line includes the `reason`, looking first
  for a top-level `reason` key and falling back to `payload`'s `reason`.
- `render(Store, CorrelationId) -> iodata()` calls
  `soma_event_store:by_correlation/2` and hands the result to `timeline/1`.

No new event types, no change to either emit path, no change to the store's write
path. The store already returns the data; this module only formats it.

The reason lookup is the one piece of real logic worth pinning down: check the
event map for a top-level `reason`; if that is absent or `undefined`, look inside
the `payload` map for a `reason`. This single rule covers both emitters without
the renderer needing to know which event came from where.

Line format is left to Dev. The criteria say which fields a line must contain,
not their separators or order. Dev picks something readable and keeps it stable
across the suite.

## Acceptance criteria → tests

All `timeline/1` criteria are pure-function checks over hand-built event maps —
no store, no processes. They go in a new EUnit module
`apps/soma_event_store/test/soma_trace_tests.erl`. The two `render/2` criteria
need a real store; the empty case is cheap EUnit against a started store, and the
end-to-end case drives an actor through a full `run_steps` task, so it belongs in
a CT suite alongside the existing correlation suite.

### Criterion 1 — one line per event
- Call chain: none (pure function). Test calls `soma_trace:timeline/1` directly
  with a list of event maps.
- Test entry: `soma_trace:timeline/1`.
- Test: `test_timeline_one_line_per_event` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 2 — lines ordered by ascending timestamp
- Call chain: none (pure function). Test passes events whose list order does not
  match timestamp order and checks the output is timestamp-sorted.
- Test entry: `soma_trace:timeline/1`.
- Test: `test_timeline_orders_by_timestamp` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 3 — each line contains the event_type
- Call chain: none (pure function).
- Test entry: `soma_trace:timeline/1`.
- Test: `test_timeline_line_names_event_type` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 4 — a line for an event with a task_id includes it
- Call chain: none (pure function).
- Test entry: `soma_trace:timeline/1`.
- Test: `test_timeline_line_includes_task_id` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 5 — a run/step/tool line with a step_id includes it
- Call chain: none (pure function).
- Test entry: `soma_trace:timeline/1`.
- Test: `test_timeline_line_includes_step_id` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 6 — a failure line includes its reason, top-level or in payload
- Call chain: none (pure function). Test passes one actor-shaped failure event
  (top-level `reason`) and one run-shaped failure event (`reason` inside
  `payload`) and checks both reasons land on their lines.
- Test entry: `soma_trace:timeline/1`.
- Test: `test_timeline_failure_reason_from_top_and_payload` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 7 — render/2 over a real driven chain is ordered and ends terminal
- Call chain: `soma_actor:start_actor` → `soma_actor:send/ask` with an `llm`
  envelope → mock LLM proposes a `run_steps` proposal → policy approves →
  `soma_run` executes the steps and emits `run.started` … `run.completed` →
  actor emits `actor.task.completed`. Test then calls
  `soma_trace:render(Store, CorrelationId)`, which calls
  `soma_event_store:by_correlation/2` then `soma_trace:timeline/1`.
- Test entry: `soma_trace:render/2`, after the actor task has been driven to
  completion. The driving uses the actor API, the same path
  `soma_actor_correlation_SUITE` already uses to produce a full chain.
- Test: `test_render_driven_chain_is_ordered_and_terminal` in
  `apps/soma_actor/test/soma_actor_correlation_SUITE.erl`

### Criterion 8 — render/2 for an unknown correlation_id is empty and does not crash
- Call chain: `soma_trace:render/2` → `soma_event_store:by_correlation/2`
  (returns `[]`) → `soma_trace:timeline/1` (returns empty iodata).
- Test entry: `soma_trace:render/2` against a freshly started store with no
  matching events.
- Test: `test_render_unknown_correlation_is_empty` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 9 — soma_trace declares no dependency on soma_actor or soma_runtime
- Call chain: none (source-file read) for the import half; pure-function call for
  the runtime half.
- Test entry: a source-level scan of `soma_trace.erl` for any `soma_actor` /
  `soma_runtime` reference, plus a `timeline/1` call over a plain list of maps
  with no runtime processes started.
- Test: `test_no_dependency_on_actor_or_runtime` in
  `apps/soma_event_store/test/soma_trace_tests.erl`

### Criterion 10 — usage.md gains a Tracing section
- Call chain: none (doc check).
- Test entry: off the call chain — this is a documentation change, verified by
  reading `docs/usage.md`. No automated test asserts prose. The new section shows
  calling `soma_trace:render/2` with a `correlation_id`, placed near the existing
  "The whole task chain by correlation_id" section.
- Test: none (doc review of `docs/usage.md`)

### Criterion 11 — rebar3 eunit && rebar3 ct is green
- Call chain: none (build/test gate).
- Test entry: the full suite run; the merge gate runs both commands.
- Test: the whole EUnit + CT run, including the new `soma_trace_tests` module and
  the new `soma_actor_correlation_SUITE` case.

## Risks & trade-offs

- The line format is unpinned. Tests assert substring presence (the event_type,
  an id, a reason appear on the right line), not an exact string. That keeps Dev
  free to choose a readable layout, at the cost of the tests not catching a format
  someone later finds ugly. Acceptable — the criteria deliberately stopped at
  "contains".
- Ordering keys on `timestamp`, which the store stamps in nanoseconds at append.
  Two events appended in the same nanosecond would tie. In practice appends are
  sequential through one gen_server, so a tie is unlikely, and a stable sort keeps
  tied events in their input order. The end-to-end test asserts the terminal event
  is last, which is the property that matters, rather than a total order over
  every pair.
- The reason fallback assumes a failure event puts its reason either at top level
  or under `payload.reason`. Both current emitters match that. A future event that
  buried the reason somewhere else would render without a reason — but adding such
  an event is out of this slice's scope.
