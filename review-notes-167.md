### Claude

## Verdict
approve

## Real issues

None.

## Questions

- The correlation_id drop the last round flagged is fixed (`ab9950e`): `resume/3` now maps `correlation_id => maps:get(correlation_id, RunOptions, undefined)` into the start opts, and `soma_run` stamps it on every resumed event. `test_resumed_run_stamps_correlation_id_from_run_options` proves `by_correlation/2` finds the resumed run's `run.completed`.
- The unsafe-path `run.failed` append (`soma_run_resume_executor.erl:34-39`) carries only `run_id`, `step_id`, `event_type`, `payload`. It drops `session_id` and `correlation_id`. So an unsafe-failed run's terminal event is invisible to `by_correlation/2` and `by_session/2` — `soma trace` on the chain shows the run dying mid-step with no terminal. Not a blocker: no criterion requires it, and the design (line 35) specs only `event_type` + `payload.reason`. But it's the same chain-severing the resumed-run path just fixed, on the path that never starts a run. Worth carrying into v0.7.5 when an actor drives `resume/3`.
- The in-flight safe resume leaves two `tool.started` for the same step — the seeded interrupted one plus the fresh one. Criterion 3 reads "any tool.started with a distinct pid," so it passes, but a reader counting attempts sees two starts for one logical step. Flagged last round; still open for v0.7.5.

## Nits

- None.

## Functional evidence
- Criterion 1 — pass: `test_between_steps_resume_starts_fresh_child_that_completes` asserts `{ok, RunPid}` with `RunPid` a member of `supervisor:which_children(soma_run_sup)` and `run.completed` on the trail with no `run.failed`.
- Criterion 2 — pass: `test_between_steps_resume_sends_owner_completed_with_merged_outputs` receives `{run_completed, RunId, Outputs}` and asserts `maps:get(s1, Outputs) =:= #{value => <<"committed">>}` (seeded) and `maps:get(s2, Outputs) =:= #{value => <<"pending">>}` (freshly run).
- Criterion 3 — pass: `test_in_flight_safe_step_reruns_in_own_worker_and_completes` seeds a `file_read` in-flight trail, resumes, asserts a fresh `tool.started` with a `tool_call_pid` distinct from `RunPid` and that `run.completed` lands.
- Criterion 4 — pass: `test_unsafe_in_flight_resume_starts_no_run` seeds a `file_write` in-flight trail, captures `active_run_children()` before/after `resume/3`, asserts the tally is unchanged.
- Criterion 5 — pass: `test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason` asserts exactly one `run.failed` whose `payload.reason` equals `{resume_unsafe, s1}`.
- Criterion 6 — pass: `test_after_unsafe_resume_reconstruct_reports_failed` asserts `soma_run_resume:reconstruct/2` returns `{ok, #{terminal_status := failed}}` after the unsafe resume.
- Criterion 7 — pass: `test_second_resume_of_unsafe_failed_run_is_terminal_noop` snapshots event list and child tally after the first unsafe resume, calls `resume/3` again, asserts both unchanged and the return is `{terminal, failed}`.
- Criterion 8 — pass: `test_resume_of_terminal_run_is_noop` seeds a `run.completed` trail, asserts event list and child tally unchanged and the return is `{terminal, completed}`.
- Criterion 9 — pass: `test_resume_of_fully_committed_run_is_nothing_to_do_noop` seeds a fully-committed single-step trail, asserts event list and child tally unchanged and the return is `nothing_to_do`.
- Criterion 10 — pass: `test_resume_of_unreconstructable_trail_returns_error_noop` seeds an orphan `step.succeeded` with no `run.started`, asserts event list and child tally unchanged and the return is `{error, no_run_started_journal}`.
- Criterion 11 — pass: `test_cancelling_resumed_run_stops_worker` captures the resumed worker pid, sends `cancel` to `RunPid`, asserts the worker is dead and `run.cancelled` lands; `test_timing_out_resumed_run_lands_terminal_event` asserts `run.timeout` lands (no `run.completed`) and `Owner` receives `{run_timeout, RunId}`.
- Criterion 12 — pass: `test_tool_crash_in_resumed_step_does_not_crash_owner` resumes into a `fail`/crash step, asserts `run.failed` lands, `Owner` receives `{run_failed, RunId, _}`, and `is_process_alive(Owner)` holds.
