# [cc] v0.4: soma_actor gen_statem starts, idle, emits actor.started (P1)

## Current state

After #55, `apps/soma_actor` has three pieces: the app callback `soma_actor_app`, the root supervisor `soma_actor_sup`, and the app resource. The supervisor is `simple_one_for_one` and its child spec forward-references a `soma_actor` worker module that does not exist yet:

```erlang
ChildSpec = #{id => soma_actor,
              start => {soma_actor, start_link, []},
              restart => temporary,
              type => worker},
```

Because a `simple_one_for_one` child spec is only resolved when `start_child/2` is called, the app boots fine today even though `soma_actor` is missing — no one starts a child. The supervisor also has no `start_actor/1` function, so there is no way to start an actor at all.

So the actor layer can boot its supervisor but cannot produce an actor. There is no worker module, no `start_actor/1`, and nothing emits `actor.started`. This slice fills exactly that gap and nothing more.

## Approach

Write `soma_actor` as a `gen_statem` and add `start_actor/1` to the supervisor. Mirror the patterns `soma_run` and `soma_run_sup` already use, so the actor layer reads the same way as the run layer.

The actor is a `gen_statem` with one state for this slice: `idle`. `callback_mode/0` returns `state_functions`, matching `soma_run`. `start_link/1` takes an `Opts` map and calls `gen_statem:start_link/3`. `init/1` reads `actor_id`, `model_config`, `tool_policy`, and `event_store` out of `Opts`, stores them in the state data, emits `actor.started`, and returns `{ok, idle, Data}`.

Event emission copies `soma_run` exactly. Build the event map with `actor_id` and `event_type => <<"actor.started">>`, call `soma_event_store:append/2`, and let the store assign `event_id` and `timestamp`. When `Opts` carries no `event_store`, emission is a no-op — the same `emit(#data{event_store = undefined}, ...)` clause `soma_run` uses. The store backfills any mandatory key the actor does not set (`session_id`, `run_id`, `step_id`, `tool_call_id`, `payload`) to `undefined`, so the actor only needs to put `actor_id` and `event_type` in the map. `actor_id` rides as an extra key the store keeps untouched. No `task_id` or `correlation_id` here — those are slice 4.

One ordering point matters for the tests. `soma_run`'s `init/1` calls `emit` before it returns `{ok, ...}`. So the event is in the store before `start_link` returns to the caller. The actor does the same: emit inside `init/1`. A test that reads the store right after `start_actor/1` returns will find the `actor.started` event already there, with no sleep or polling.

For the state-readout criterion the issue leaves the choice open. This design picks `sys:get_state/1` against the `gen_statem` and adds no status call. `sys:get_state/1` on a `state_functions` `gen_statem` returns `{StateName, Data}`, so a test reads both the `idle` state name and the data record in one call. The data record holds `actor_id`, `model_config`, and `tool_policy` as fields. This keeps the slice's surface to exactly the three exports the first criterion names (`start_link/1`, `callback_mode/0`, `init/1`) plus the supervisor's `start_actor/1`. A status call can come in a later slice when there is real state worth a public read; adding one now would be surface this slice does not need.

`soma_actor_sup:start_actor/1` copies `soma_run_sup:start_run/1` line for line: `supervisor:start_child(?MODULE, [Opts])` against the existing `simple_one_for_one` spec. The spec already points at `{soma_actor, start_link, []}`, so once the worker module exists, `start_child` with `[Opts]` calls `soma_actor:start_link(Opts)` and returns `{ok, Pid}`.

No `send`, no `ask`, no runs, no tool logic. The actor boots, sits in `idle`, holds its config, records its start, and waits. That is the whole slice.

## Acceptance criteria → tests

The proof suite is `soma_actor_SUITE` (Common Test), the planned suite P1 names in `docs/contracts/v0.4-test-contract.md`. The behaviour/export criteria are compile-and-introspect checks that also belong there so the contract has one home. The event-store-backed criteria need a live `soma_event_store`, which a CT suite starts per case in `init_per_testcase`.

### Criterion 1 — soma_actor is a gen_statem and exports the three callbacks
- Call chain: none (compile-time + module introspection)
- Test entry: off the call chain — this asserts the module's shape, not a behaviour. The test reads `soma_actor:module_info(attributes)` for `{behaviour, [gen_statem]}` and `module_info(exports)` for `start_link/1`, `callback_mode/0`, `init/1`. Compilation against the `gen_statem` behaviour is itself part of the proof.
- Test: `actor_is_gen_statem_with_callbacks` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 2 — start_actor/1 returns {ok, Pid}
- Call chain: `soma_actor_sup:start_actor/1` → `supervisor:start_child/2` → `soma_actor:start_link/1` → `gen_statem:start_link/3` → `soma_actor:init/1`
- Test entry: `soma_actor_sup:start_actor/1` (the real caller's entry, no layer bypassed)
- Test: `start_actor_returns_ok_pid` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 3 — the actor pid is alive right after start
- Call chain: `soma_actor_sup:start_actor/1` → `supervisor:start_child/2` → `soma_actor:start_link/1` → `soma_actor:init/1`
- Test entry: `soma_actor_sup:start_actor/1`; the test then calls `is_process_alive(Pid)` on the returned pid
- Test: `actor_alive_after_start` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 4 — the actor is in state idle right after start
- Call chain: `soma_actor_sup:start_actor/1` → `soma_actor:start_link/1` → `soma_actor:init/1` (returns `{ok, idle, Data}`)
- Test entry: `soma_actor_sup:start_actor/1`; the test then calls `sys:get_state(Pid)` and matches the state name `idle` in the returned `{StateName, Data}`
- Test: `actor_starts_idle` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 5 — the state holds actor_id, model_config, tool_policy
- Call chain: `soma_actor_sup:start_actor/1` → `soma_actor:start_link/1` → `soma_actor:init/1` (stores the three opts in the data record)
- Test entry: `soma_actor_sup:start_actor/1`; the test then reads the data record from `sys:get_state(Pid)` and asserts the three values match the `Opts` it passed
- Test: `actor_state_holds_config` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 6 — the store holds exactly one actor.started event
- Call chain: `soma_actor_sup:start_actor/1` → `soma_actor:init/1` → `soma_actor` emit helper → `soma_event_store:append/2`
- Test entry: `soma_actor_sup:start_actor/1` with a live `event_store` in `Opts`; the test then calls `soma_event_store:all/1` and asserts exactly one event with `event_type =:= <<"actor.started">>`. Emission happens inside `init/1` before `start_link` returns, so no wait is needed.
- Test: `start_emits_one_actor_started_event` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 7 — the actor.started event carries actor_id
- Call chain: `soma_actor_sup:start_actor/1` → `soma_actor:init/1` → `soma_actor` emit helper → `soma_event_store:append/2`
- Test entry: `soma_actor_sup:start_actor/1` with a live `event_store`; the test reads the one `actor.started` event from `soma_event_store:all/1` and asserts its `actor_id` equals the `actor_id` passed in `Opts`
- Test: `actor_started_event_carries_actor_id` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 8 — an actor with no event_store boots, stays alive, emits nothing
- Call chain: `soma_actor_sup:start_actor/1` → `soma_actor:start_link/1` → `soma_actor:init/1` (emit hits the `event_store = undefined` no-op clause)
- Test entry: `soma_actor_sup:start_actor/1` with `Opts` that omit `event_store`; the test asserts `{ok, Pid}`, `is_process_alive(Pid)`, and state `idle`. There is no store to read, so the proof of "emits nothing" is that the actor neither crashed nor needed a store — the no-op clause is exercised by the actor staying alive.
- Test: `actor_without_event_store_boots_quietly` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 9 — soma_actor_sup exports start_actor/1 mirroring soma_run_sup:start_run/1
- Call chain: `soma_actor_sup:start_actor/1` → `supervisor:start_child/2`
- Test entry: `soma_actor_sup:start_actor/1`. Covered behaviourally by criteria 2–7, which all enter through it. A direct export check (`soma_actor_sup:module_info(exports)` lists `start_actor/1`) pins the export name itself.
- Test: `sup_exports_start_actor` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 10 — rebar3 eunit && rebar3 ct is green
- Call chain: none (build/test-run gate)
- Test entry: off the call chain — this is the merge gate, not a single test. It passes when the new `soma_actor_SUITE` cases pass and the existing EUnit/CT suites stay green.
- Test: the full `rebar3 eunit && rebar3 ct` run; no dedicated test function

## Risks & trade-offs

`sys:get_state/1` reaches into the `gen_statem`'s internal data record, so a test that pattern-matches the whole record breaks if a later slice reorders or adds fields. The mitigation is to have the test pull fields by position or match a partial record with `_` for the rest, not bind the entire tuple — Dev decides the exact form when writing the test. Choosing `sys:get_state/1` over a public status call trades a stable public read for a smaller module surface this slice; slice 6 adds `get_task_status` / `get_task_result` and can carry a status read then if one is wanted.

Criterion 8 cannot positively prove "emitted nothing" without a store to inspect. The test proves the weaker, real thing: the actor boots and stays alive with no store. The no-op emit clause is the same one `soma_run` already relies on, so the behaviour is not new code paths' worth of risk.
