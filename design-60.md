# [cc] v0.4: soma_actor send/2 ingests envelope, mints task/correlation id (P2)

## Current state

`soma_actor` is a `gen_statem` in `state_functions` mode. After #58 it has a
`#data{actor_id, model_config, tool_policy, event_store}` record, boots into
`idle`, and emits `actor.started` once during `init/1`. Its `idle/3` clause
ignores every event and keeps state. `emit/2` appends `#{actor_id, event_type}`
to the store, with a no-op clause when `event_store` is `undefined`.

So the actor exists but has no way in. There is no `send/2`, no task table, and
no path that turns an incoming message into a recorded task. This slice adds the
message entry point.

## Approach

Add `soma_actor:send/2` as a synchronous `gen_statem:call`. The public function
wraps the envelope and calls into the actor; the work happens in the `idle/3`
`{call, From}` clause so it runs inside the actor process, not in the caller. The
actor never gets bypassed.

`send(ActorRef, Envelope)` returns `{ok, TaskId} | {error, Reason}`. It returns
once the task is recorded and the two events are emitted. There is no downstream
work yet, so it does not block on a run.

Steps inside the `idle/3` call clause:

1. Validate the envelope. A non-map fails. A map missing a required field fails.
   The required set is `type` and `payload` — the fields that say what work to
   do. `task_id` and `correlation_id` are minted or defaulted here, so they
   cannot be required. On failure, reply `{error, Reason}` and `keep_state` so
   the actor stays in `idle` and alive.
2. Resolve `task_id`: take the envelope's `task_id` if present, else mint a fresh
   non-empty binary. Minting follows the existing pattern in
   `soma_agent_session` — `list_to_binary("task-" ++
   integer_to_list(erlang:unique_integer([positive, monotonic])))`.
3. Resolve `correlation_id`: take the envelope's `correlation_id` if present,
   else default to the resolved `task_id`.
4. Record the task in a per-actor task table held in `#data`. Add a `tasks`
   field — a map keyed by `task_id`, each value at least `#{correlation_id,
   status}`, with `status => accepted`. Appending a record field keeps the
   first four field positions stable, so #58's position-based state assertions
   still hold.
5. Emit `actor.message.received` then `actor.task.accepted`, both carrying
   `task_id` and `correlation_id`.
6. Reply `{ok, TaskId}` and `keep_state` with the updated data.

Grow `emit` to `emit(Data, Type, Extra)`, mirroring `soma_run`'s shape: build a
base map of `#{actor_id, event_type}`, merge `Extra` over it, append the result.
The `undefined`-store clause stays a no-op. The #58 `init/1` call becomes
`emit(Data, <<"actor.started">>, #{})`.

The task table read needed by the criteria is small. `sys:get_state/1` already
exposes `#data`, and the new `tasks` field sits at a known record position, so a
test can pull it the same way #58 pulls config fields. No `get_task_status`
function is added here — that is slice 6.

## Acceptance criteria → tests

All tests are CT cases in
`apps/soma_actor/test/soma_actor_SUITE.erl`, the suite #58 established. Each
enters through the real `soma_actor:send/2` call (the actor mailbox), never by
poking state directly. The actor is started through `soma_actor_sup:start_actor/1`
as in #58.

### Criterion 1 — send returns the envelope's task_id when it carries one
- Call chain: test → `soma_actor:send/2` → `gen_statem:call` → `idle/3`
  `{call, From}` clause → envelope validate → task_id resolve → reply `{ok, TaskId}`
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `send_returns_envelope_task_id` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 2 — send mints a fresh non-empty task_id when the envelope has none
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → task_id mint → reply `{ok, TaskId}`
- Test entry: `soma_actor:send/2`; the test sends an envelope with no `task_id`
  and asserts the returned `TaskId` is a non-empty binary
- Test: `send_mints_task_id_when_absent` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 3 — recorded correlation_id equals the envelope's when present
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → correlation_id
  resolve → task recorded in `#data.tasks` → reply `{ok, TaskId}`; test then reads
  the table through `sys:get_state/1`
- Test entry: `soma_actor:send/2`; the post-call table read uses `sys:get_state/1`
  because no status-read function exists in this slice
- Test: `correlation_id_from_envelope_when_present` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 4 — correlation_id defaults to task_id when the envelope has none
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → correlation_id
  defaults to resolved task_id → task recorded → reply `{ok, TaskId}`; test reads
  the table through `sys:get_state/1`
- Test entry: `soma_actor:send/2`; table read uses `sys:get_state/1` for the same
  reason as Criterion 3
- Test: `correlation_id_defaults_to_task_id` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 5 — a non-map envelope returns {error, Reason}, actor stays alive
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → validate
  rejects non-map → reply `{error, Reason}` + `keep_state`; test then checks
  `is_process_alive/1` on the actor pid
- Test entry: `soma_actor:send/2`
- Test: `non_map_envelope_errors_actor_survives` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 6 — missing required field returns {error, Reason}, actor stays alive
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → validate finds
  a required field missing → reply `{error, Reason}` + `keep_state`; test then
  checks `is_process_alive/1`
- Test entry: `soma_actor:send/2`; the test omits `payload` (a required field) to
  trigger the rejection
- Test: `missing_field_envelope_errors_actor_survives` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 7 — actor.message.received carries actor_id, task_id, correlation_id
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → `emit(Data,
  <<"actor.message.received">>, #{task_id, correlation_id})` →
  `soma_event_store:append/2`; test reads the store with `soma_event_store:all/1`
- Test entry: `soma_actor:send/2`; the event read goes through the live event
  store, the same store the actor emits into
- Test: `message_received_event_carries_ids` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 8 — actor.task.accepted carries the same ids as message.received
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → two `emit`
  calls → store; test reads both events with `soma_event_store:all/1` and
  compares their `actor_id`, `task_id`, `correlation_id`
- Test entry: `soma_actor:send/2`
- Test: `task_accepted_event_matches_received_ids` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 9 — accepted task_id is in the task table with status accepted
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → task recorded
  in `#data.tasks` with `status => accepted`; test reads the table through
  `sys:get_state/1`
- Test entry: `soma_actor:send/2`; the table read uses `sys:get_state/1` since
  this slice adds no status-read function
- Test: `accepted_task_in_table_with_status` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 10 — after a valid send the actor is still alive and in idle
- Call chain: test → `soma_actor:send/2` → `idle/3` call clause → reply + `keep_state`;
  test then checks `is_process_alive/1` and `sys:get_state/1` returns `{idle, _}`
- Test entry: `soma_actor:send/2`
- Test: `actor_idle_and_alive_after_send` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 11 — a second send with a different task_id also returns {ok, TaskId}
- Call chain: test → `soma_actor:send/2` (first) → `idle/3` → reply; test →
  `soma_actor:send/2` (second, different task_id) → `idle/3` → reply `{ok, TaskId}`
- Test entry: `soma_actor:send/2`, called twice on the same actor pid
- Test: `second_send_accepts_too` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 12 — rebar3 eunit && rebar3 ct is green
- Call chain: none (build/gate assertion)
- Test entry: the relay merge gate runs `rebar3 eunit && rebar3 ct`
- Test: the full suite run, no dedicated case

## Risks & trade-offs

The required-field set (`type`, `payload`) is a judgment call. The doc lists the
envelope fields but never marks any mandatory. If a later slice needs `from` or
`to` present, the validation set will have to grow, and that change touches every
test that builds a minimal valid envelope. The cost is real but small at this
size.

The task table read leans on `sys:get_state/1` and a known record position. That
ties the criterion-9 test to `#data`'s internal layout. The alternative — adding
a status-read function now — pulls slice-6 surface into this slice, which the
issue puts out of scope. Position-based reads are what #58 already does, so this
keeps the suite consistent rather than mixing two styles.
