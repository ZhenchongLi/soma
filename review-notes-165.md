### Claude

## Verdict
approve

## Real issues
None.

## Questions
None.

## Nits
- `classify/3`'s third clause binds `NextStep = #{id := NextId, tool := Tool}` and passes `NextStep` to `pending_suffix/2`, which re-destructures `#{id := NextId}`. The id is already in hand. Minor; not worth a round.

## Functional evidence
- Criterion 1 — pass: `test_between_steps_resumes_with_pending_suffix_outputs_and_options` seeds `[s1,s2]`, commits `s1`, no `tool.started` for `s2`; asserts `{resume, P}` with `pending=[s2]`, `steps=[s1,s2]`, `outputs=#{s1 => #{value => <<"committed">>}}`, `run_options` equal to the journal. Green.
- Criterion 2 — pass: `test_in_flight_safe_step_resumes` seeds `next_step` on `file_read` (reader/idempotent) with a `tool.started`; asserts `{resume, _}`. `file_read` descriptor carries `effect => reader, idempotent => true` (`soma_tool_file_read.erl:13`). Green.
- Criterion 3 — pass: `test_in_flight_unsafe_state_step_is_unsafe` seeds `next_step` on `file_write` with a `tool.started`; asserts `{unsafe, s1}` and `assertNotMatch({resume,_})`. `file_write` descriptor carries `effect => state, idempotent => false` (`soma_tool_file_write.erl:13`). Green.
- Criterion 4 — pass: `test_terminal_trail_returns_terminal_status_over_next_step` seeds `[s1,s2]` with `s2` uncommitted plus `run.failed`; asserts `{terminal, failed}` and not `{resume,_}`; second case maps `run.completed` to `{terminal, completed}`. The terminal clause sits before the `next_step` clause in `classify/3`. Green.
- Criterion 5 — pass: `test_all_committed_no_terminal_is_nothing_to_do` seeds a single committed step, no terminal event; reconstruct returns `next_step => undefined`; asserts `nothing_to_do`. Green.
- Criterion 6 — pass: `test_propagates_reconstruct_errors` covers both: orphan `step.succeeded` returns `{error, no_run_started_journal}`; a committed `s_undeclared` not in the journal returns `{error, {unknown_committed_step, s_undeclared}}`. `plan/2` passes `{error,_}` straight back. Green.
- Criterion 7 — pass: `test_plan_is_read_only` runs a real session to completion, snapshots `soma_event_store:all/1` and `supervisor:count_children(soma_run_sup)` before/after; asserts both equal. Green.
- Criterion 8 — pass: `test_resume_payload_has_four_seam_fields` asserts `lists:sort(maps:keys(P)) =:= [outputs, pending, run_options, steps]`, then feeds the four fields plus `run_id`/`event_store` into `soma_run:start_link/1` and asserts the resumed run reaches `run.completed` with no `run.failed`. Green.

Gate: `rebar3 eunit` 255/0, `rebar3 ct` 321/0 (8 of them this suite).
