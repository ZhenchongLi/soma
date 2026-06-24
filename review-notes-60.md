### Claude

## Verdict
approve

## Real issues
None.

## Questions
- Emitted events carry only `actor_id`, `event_type`, `task_id`, `correlation_id`. CLAUDE.md says every event carries `event_id, timestamp, session_id, run_id, step_id, tool_call_id`. `actor.started` from #58 already omits them and the criteria don't ask for them here, so this slice didn't regress anything. When does the actor event shape get filled out — a later slice, or does the actor path keep a thinner envelope on purpose?
- `correlation_id` defaults to `task_id`. When the envelope omits `task_id` too, the minted task id becomes the correlation id. Is a minted id a meaningful correlation key, or does a caller that wants real correlation always have to supply it?

## Nits
- `validate_envelope/1` collapses non-map and missing-field into one `{error, Reason}` shape with distinct reasons (`not_a_map`, `missing_required_field`). Good. The reason atom never names *which* field is missing — fine at two required fields, will want naming if the set grows.

## Functional evidence
- Criterion 1 — pass: `send_returns_envelope_task_id` asserts `{ok, <<"task-from-envelope">>} = soma_actor:send(Pid, Envelope)` where the envelope carries that `task_id`. soma_actor.erl:64-68 returns the envelope's id when present.
- Criterion 2 — pass: `send_mints_task_id_when_absent` sends an envelope with no `task_id`, asserts `is_binary(TaskId)` and `byte_size(TaskId) > 0`. `mint_task_id/0` builds `<<"task-", N>>` from a positive monotonic unique integer.
- Criterion 3 — pass: `correlation_id_from_envelope_when_present` reads the task table via `sys:get_state/1`, element 6, and asserts the recorded `correlation_id` equals `<<"corr-from-envelope">>`.
- Criterion 4 — pass: `correlation_id_defaults_to_task_id` sends an envelope with `task_id` but no `correlation_id`, reads the table, asserts `TaskId = maps:get(correlation_id, Task)`. `resolve_correlation_id/2` defaults to `TaskId`.
- Criterion 5 — pass: `non_map_envelope_errors_actor_survives` sends `<<"not-a-map">>`, asserts `{error, _}` then `is_process_alive(Pid)`. Validate clause returns `{error, not_a_map}` with `keep_state`.
- Criterion 6 — pass: `missing_field_envelope_errors_actor_survives` omits `payload`, asserts `{error, _}` then `is_process_alive(Pid)`. Returns `{error, missing_required_field}` with `keep_state`.
- Criterion 7 — pass: `message_received_event_carries_ids` reads the live store with `soma_event_store:all/1`, finds the single `actor.message.received` event, asserts its `actor_id`, `task_id`, `correlation_id` match the call.
- Criterion 8 — pass: `task_accepted_event_matches_received_ids` pulls both `actor.message.received` and `actor.task.accepted` from the store and asserts all three ids equal across them.
- Criterion 9 — pass: `accepted_task_in_table_with_status` reads element 6 of `#data`, asserts `maps:is_key(TaskId, Tasks)` and `accepted = maps:get(status, Task)`.
- Criterion 10 — pass: `actor_idle_and_alive_after_send` asserts `is_process_alive(Pid)` and `{idle, _} = sys:get_state(Pid)` after a valid send. Call clause uses `keep_state`.
- Criterion 11 — pass: `second_send_accepts_too` calls `send/2` twice on the same pid with `task-one` then `task-two`, asserts each returns its own `{ok, TaskId}`.
- Criterion 12 — pass: `rebar3 eunit && rebar3 ct` green — EUnit 108 tests 0 failures, CT 90 tests passed.
