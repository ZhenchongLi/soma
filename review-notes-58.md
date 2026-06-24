### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `actor.started` carries `actor_id` + `event_type` only; the store backfills `session_id`, `run_id`, `step_id`, `tool_call_id`, `payload` to `undefined`. `actor_id` rides as an extra key the store leaves alone. Fine for this slice — an actor has no session or run yet. Flagging so a later slice that wires actors under a session sets `session_id` instead of leaning on the `undefined` backfill.

## Nits
- `idle/3` is exported and matches every event with `{keep_state, Data}`. Dead until a later slice sends the actor something. Matches `soma_run`'s shape, leave it.

## Functional evidence
- Criterion 1 — pass: `soma_actor.erl:7` declares `-behaviour(gen_statem)`; lines 9-10 export `start_link/1`, `callback_mode/0`, `init/1`. `actor_is_gen_statem_with_callbacks` reads `module_info` and asserts all three plus the behaviour. CT green.
- Criterion 2 — pass: `start_actor_returns_ok_pid` calls `soma_actor_sup:start_actor/1`, matches `{ok, Pid}`, `is_pid(Pid)` true. CT green.
- Criterion 3 — pass: `actor_alive_after_start` matches `{ok, Pid}` then `is_process_alive(Pid)` = true. CT green.
- Criterion 4 — pass: `actor_starts_idle` matches `{idle, _Data} = sys:get_state(Pid)`; `init/1` returns `{ok, idle, Data}` at `soma_actor.erl:27`. CT green.
- Criterion 5 — pass: `actor_state_holds_config` pulls `element(2/3/4, Data)` = actor_id/model_config/tool_policy from the `#data` record (fields 1-3 after the tag, `soma_actor.erl:13`). CT green.
- Criterion 6 — pass: `start_emits_one_actor_started_event` reads `soma_event_store:all/1`, filters `event_type =:= <<"actor.started">>`, asserts `length = 1`. `init/1` emits before returning. CT green.
- Criterion 7 — pass: `actor_started_event_carries_actor_id` binds the single `actor.started` event and asserts `maps:get(actor_id, Started) =:= <<"actor-evt">>`. `emit/2` puts `actor_id` in the map (`soma_actor.erl:35`). CT green.
- Criterion 8 — pass: `actor_without_event_store_boots_quietly` starts with no `event_store`, asserts `is_process_alive` + `{idle, _}`. Hits the `emit(#data{event_store = undefined}, _)` no-op clause (`soma_actor.erl:32`). CT green.
- Criterion 9 — pass: `soma_actor_sup.erl:18-19` defines `start_actor/1` = `supervisor:start_child(?MODULE, [Opts])`, line-for-line with `soma_run_sup:start_run/1`. `sup_exports_start_actor` pins the export. CT green.
- Criterion 10 — pass: `rebar3 eunit` = 108 tests 0 failures; `rebar3 ct` = 79 tests passed (9 in `soma_actor_SUITE`).
