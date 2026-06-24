# [cc] v0.4: by_correlation/2 + soma_run stamps correlation_id, full-chain lookup (P7)

## Current state

The actor already knows a task's `correlation_id`. It resolves it from the envelope (falling back to the task id), records it on the task, and stamps it on its own four `actor.*` events. When it starts a run it also passes that `correlation_id` into the run's start opts (`soma_actor.erl`, `maybe_start_run/4`). So the id is already flowing into the run layer.

Two gaps remain.

First, `soma_run` drops the opt. `init/1` reads `run_id`, `session_id`, `session_pid`, `event_store`, and `steps` out of opts but never reads `correlation_id`. The `emit/3` helper builds each event from a fixed base of `session_id`, `run_id`, `event_type`, merged with the per-call extra. So no `run.*` event carries a `correlation_id`, even when the run was started with one.

Second, the event store can't query by `correlation_id`. It has `by_run/2` and `by_session/2`, each a filter over the reversed event list comparing one `maps:get` against the argument. There is no `by_correlation/2`.

The result: today you can pull the four `actor.*` events for a task with a manual filter, but the run's `run.started` through `run.completed` chain is unreachable under the same id. The whole point of a correlation id — one lookup that returns the entire actor-plus-run trail — does not work yet.

## Approach

Two production changes, both additive.

Add `soma_event_store:by_correlation/2`. It mirrors `by_run/2` exactly: a `handle_call({by_correlation, CorrelationId}, ...)` clause that walks `lists:reverse(Events)` and keeps events where `maps:get(correlation_id, E, undefined) =:= CorrelationId`, returning them oldest-first in append order. Export it alongside `by_run/2` and `by_session/2`. It reads `correlation_id` with an `undefined` default, so an event that never carried the key simply doesn't match — no crash. We do not touch `?MANDATORY_KEYS`. `correlation_id` stays an optional field, present only on events that set it, never backfilled to `undefined` like the eight mandatory keys are. That keeps `by_correlation/2` honest: it matches only events that actually carry the id, and a never-stored id returns `[]`.

Make `soma_run` stamp the id. Read `correlation_id` from opts in `init/1` (default `undefined`) into a new `correlation_id` field on the `#data{}` record. Then change `emit/3` so that when the run holds a non-`undefined` `correlation_id`, every event it appends carries it; when the run was started without one, no event carries the key. The cleanest way to honor "no `correlation_id` opt → no `correlation_id` on any event" is to add the key to the event base only when it is set, rather than always merging `correlation_id => undefined`. That way a run with no id emits exactly the trail it emits today, byte-for-byte, and `by_correlation/2` on an unrelated id still returns `[]`.

No `soma_actor` change. It already emits and forwards the id. Once the run stamps and the store can query, the full chain falls out: the four `actor.*` events and the run's `run.*` chain all carry `C`, so `by_correlation(Store, C)` returns the whole thing in append order.

Scope is the completion path only. Failure, timeout, and cancel trails will also carry the id for free (they go through the same `emit/3`), but this slice proves the completion chain, matching the issue's out-of-scope note.

## Acceptance criteria → tests

### Criterion 1 — by_correlation/2 filters by correlation_id, oldest-first
- Call chain: `soma_event_store:by_correlation/2` → `gen_server:call` → `handle_call({by_correlation, _}, ...)`
- Test entry: `soma_event_store:by_correlation/2` (the public API call, no layer bypassed)
- Test: `test_by_correlation_filters` in `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 2 — by_correlation/2 returns [] for an unknown id
- Call chain: `soma_event_store:by_correlation/2` → `gen_server:call` → `handle_call({by_correlation, _}, ...)`
- Test entry: `soma_event_store:by_correlation/2` (the public API call, no layer bypassed)
- Test: `test_by_correlation_empty_for_unknown_id` in `apps/soma_event_store/test/soma_event_store_tests.erl`

### Criterion 3 — a run started with a correlation_id stamps it on every event
- Call chain: `soma_run:start_link/1` → `init/1` → `emit/3` (run.started through run.completed) → `soma_event_store:append/2`; read back with `soma_event_store:by_correlation/2`
- Test entry: `soma_run:start_link/1`. The test starts the run directly rather than through `soma_agent_session:start_run/2`, because the session's `start_run/2` takes only a steps list and has no way to pass a `correlation_id` opt. The run is the unit under test for stamping, and starting it directly is the only caller path that carries a `correlation_id` opt without an actor.
- Test: `test_run_stamps_correlation_id_on_every_event` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 4 — a run started with no correlation_id emits its normal trail, no id
- Call chain: `soma_run:start_link/1` → `init/1` → `emit/3` (run.started through run.completed) → `soma_event_store:append/2`; read back with `soma_event_store:by_run/2`
- Test entry: `soma_run:start_link/1`. Same reason as criterion 3: the opt is set or omitted on the run's start opts, so the test starts the run directly with the opt omitted.
- Test: `test_run_without_correlation_id_emits_normal_trail` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 5 — full actor-plus-run chain retrievable under one id
- Call chain: `soma_actor:send/2` → `idle/3` (`{send, Envelope}`) → `maybe_start_run/4` → `soma_run_sup:start_run/1` → `soma_run:init/1` → run drives to `run.completed` → `{run_completed, ...}` back to the actor's `idle/3` → `actor.result.created` + `actor.task.completed`; read back with `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2` (the real actor entry, no layer bypassed). The test boots `soma_runtime` so `soma_run_sup`, `soma_tool_registry`, and the shared event store are live, drives one task with a known `correlation_id` C, waits for `actor.task.completed`, then asserts `by_correlation(Store, C)` returns the four `actor.*` events together with the run's `run.*` chain including the step and tool events.
- Test: `test_chain_retrievable_by_correlation_id` in `apps/soma_actor/test/soma_actor_correlation_SUITE.erl`

### Criterion 6 — rebar3 eunit && rebar3 ct is green
- Call chain: none (build-gate assertion)
- Test entry: the merge gate runs `rebar3 eunit && rebar3 ct`
- Test: the full EUnit and Common Test suites, including the five cases above

## Risks & trade-offs

Criteria 3 and 4 start `soma_run` directly instead of going through a session. That means those two tests prove the run stamps what it is handed, but not that any real caller hands a run a `correlation_id` through the session path. That gap is acceptable here: the actor is the real caller that forwards the id, and criterion 5 proves the actor → run → store chain end to end through `soma_actor:send/2`. The session's `start_run/2` is out of scope for this slice and carries no correlation id by design.

Keeping `correlation_id` off the mandatory-key set means events split into two shapes — eight keys, or eight plus `correlation_id`. Code that assumes every event has the same key set must use `maps:get(correlation_id, E, undefined)`, which is what `by_correlation/2` does. The alternative, adding the key to the mandatory set, is explicitly out of scope and would change every existing event's shape and the `test_event_has_all_eight_fields` assertion. The two-shape cost is the smaller one.
