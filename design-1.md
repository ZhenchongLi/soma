# [cc] In-memory event store (soma v0.1 foundation)

## Current state

`apps/soma_event_store/` has only `soma_event_store.app.src`. There is no
`soma_event_store.erl` module, so nothing can hold events yet.

The README makes events mandatory in v0.1. Every action in a run has to emit an
event so a completed, failed, cancelled, or timed-out run can be read back from
the log alone. Each event carries 8 fields: `event_id`, `timestamp`,
`session_id`, `run_id`, `step_id`, `tool_call_id`, `event_type`, `payload`.

None of the layers that will emit these events exist yet either. The session,
run, and tool-call processes are later issues. This issue builds only the store
they will write into. The store does not run anything and does not call tools.
It appends events and reads them back.

## Approach

Add `soma_event_store` as a `gen_server` in
`apps/soma_event_store/src/soma_event_store.erl`. It keeps events in memory in a
single process and answers reads.

Key decisions:

- **Storage is an in-order list inside the gen_server state.** Append puts the
  new event at the front; reads reverse it once to hand back append order. A
  plain list is enough for v0.1 and keeps the whole store in one process, which
  is the audit substrate the run layer needs and nothing more.
- **The store fills in `event_id` and `timestamp` on append, not the caller.**
  `event_id` is generated per append so it stays unique across a sequence even
  if two callers pass identical payloads. If the caller leaves `timestamp` out
  (or passes `undefined`), the store stamps it with the current time at append.
  A caller-supplied timestamp is kept as given.
- **The store normalizes every event to all 8 keys.** A caller that omits
  `step_id` or `tool_call_id` (a `session.started` event has neither) gets
  `undefined` filled in for the missing keys. This matches the issue's open
  question: missing fields are `undefined`, never dropped, so every stored event
  has all 8 keys when read back.
- **No validation of `event_type`.** The store records whatever type it is
  given. A closed set is out of scope.
- **The store is started with `start_link` directly in tests.** Wiring it into
  `soma_sup` is a later issue, so tests own the process lifecycle.

Public API (shape, not implementation):

- `start_link/0` — start the store process.
- `append/2` — append one event map, store fills `event_id` and `timestamp`.
- `all/1` — read every event in append order.
- `by_run/2` — read events whose `run_id` matches.
- `by_session/2` — read events whose `session_id` matches.

Tests are EUnit in `apps/soma_event_store/test/soma_event_store_tests.erl`. Each
test starts a fresh store with `start_link`, appends, and reads back. These are
unit tests against the store API. There is no supervision tree and no run layer
to go through, because neither exists yet.

## Acceptance criteria → tests

### Criterion 1 — reads come back in append order
- Call chain: none (direct API call). Test starts the store, calls `append/2`
  several times, then `all/1`.
- Test entry: `soma_event_store:all/1` after a sequence of `append/2` calls. No
  layer is bypassed because the store is the only layer.
- Test: `test_all_returns_append_order` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 2 — filter by `run_id` returns only matching events
- Call chain: none (direct API call). Append events under two different
  `run_id`s, then call `by_run/2` with one of them.
- Test entry: `soma_event_store:by_run/2`.
- Test: `test_by_run_filters` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 3 — filter by `session_id` returns only matching events
- Call chain: none (direct API call). Append events under two different
  `session_id`s, then call `by_session/2` with one of them.
- Test entry: `soma_event_store:by_session/2`.
- Test: `test_by_session_filters` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 4 — every read-back event has all 8 mandatory fields
- Call chain: none (direct API call). Append an event that omits `step_id` and
  `tool_call_id`, read it back, check the map has all 8 keys.
- Test entry: `soma_event_store:append/2` then `all/1`. The test asserts on the
  map keys of the returned event.
- Test: `test_event_has_all_eight_fields` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 5 — `event_id` is unique across a sequence of appends
- Call chain: none (direct API call). Append several events (including two with
  identical payloads), read them all back, collect the `event_id`s.
- Test entry: `soma_event_store:append/2` repeated, then `all/1`. The test
  asserts the `event_id` list has no duplicates.
- Test: `test_event_id_unique` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 6 — append with no `timestamp` gets one filled in
- Call chain: none (direct API call). Append an event with no `timestamp` key,
  read it back, check `timestamp` is set and is not `undefined`.
- Test entry: `soma_event_store:append/2` then `all/1`.
- Test: `test_timestamp_filled_when_absent` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 7 — querying an empty store returns an empty list
- Call chain: none (direct API call). Start the store, call `all/1` (and the two
  filters) without appending anything.
- Test entry: `soma_event_store:all/1`, `by_run/2`, `by_session/2` on a fresh
  store.
- Test: `test_empty_store_returns_empty_list` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 8 — store process stays alive after a query against an empty store
- Call chain: none (direct API call). Start the store, query it while empty,
  then check the process is still alive with `is_process_alive/1`.
- Test entry: `soma_event_store:all/1` on a fresh store, followed by a liveness
  check on the store pid. This asserts process survival, not just the return
  value, which is the README's test rule.
- Test: `test_store_survives_empty_query` in
  `apps/soma_event_store/test/soma_event_store_tests.erl`

## Risks & trade-offs

- **A list grows without bound.** Every appended event stays in memory for the
  life of the process and there is no eviction. For v0.1 this is fine because
  the store is short-lived and used in tests. A persistent or bounded store is a
  later issue.
- **Reversing on every read costs O(n).** With append-at-front and reverse-on-
  read, a read walks the whole list. At v0.1 event counts this does not matter.
  If reads ever get hot, the store can keep the list in forward order or index
  by `run_id`, but that is not worth doing now.
- **`event_id` uniqueness depends on the generation scheme.** If the store used
  wall-clock time as the id, two appends in the same instant could collide. The
  id has to come from a source that is unique per append (a monotonic counter or
  a reference), and the test for criterion 5 is what holds that line.
