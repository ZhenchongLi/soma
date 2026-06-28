### Claude

## Verdict
changes-requested

## Real issues

- **The resumed run drops `correlation_id`.** `soma_run_resume_executor:resume/3` builds `Opts` from `run_options` — it maps `run_id` and `session_id` out, but never `correlation_id` (`apps/soma_runtime/src/soma_run_resume_executor.erl:24-30`). The v0.7.1 journal allowlist carries `correlation_id` for one reason: a resumed run rejoins its chain. The executor strips it, so the resumed run starts with `correlation_id => undefined` and stamps none of its events. `by_correlation/2` won't find the resumed work — `soma trace` on the original correlation id shows the run dying mid-step and nothing after. The design says (line 39) "`correlation_id` and `session_id` are left to whatever `run_options` carried"; the code honors that for `session_id` and breaks it for `correlation_id`. Fix: map `correlation_id => maps:get(correlation_id, RunOptions, undefined)` into `Opts`. The moment v0.7.5 points an actor at `resume/3`, every actor run carries a correlation_id and every resume severs the chain.

## Questions

- The in-flight safe resume leaves two `tool.started` events for the same step on the trail — the original (interrupted) one plus the fresh one the resumed run emits. Criterion 3's test reads "any tool.started with a distinct pid," so it passes, but a later reader counting attempts sees two starts for one logical step. Intended, or should the journal mark the original as superseded? Not a blocker for this slice; flagging for v0.7.5.

## Nits

- None.

## Functional evidence
- Criterion 1 — pass: `test_between_steps_resume_starts_fresh_child_that_completes` asserts `{ok, RunPid}` with `RunPid` a live member of `supervisor:which_children(soma_run_sup)` and `run.completed` on the trail with no `run.failed`.
- Criterion 2 — pass: `test_between_steps_resume_sends_owner_completed_with_merged_outputs` receives `{run_completed, RunId, Outputs}` and asserts `maps:get(s1, Outputs) =:= #{value => <<"committed">>}` (seeded) and `maps:get(s2, Outputs) =:= #{value => <<"pending">>}` (freshly run).
- Criterion 3 — pass: `test_in_flight_safe_step_reruns_in_own_worker_and_completes` seeds a `file_read` in-flight trail, resumes, asserts a fresh `tool.started` with `tool_call_pid` distinct from `RunPid` and `run.completed` lands.
- Criterion 4 — pass: `test_unsafe_in_flight_resume_starts_no_run` seeds a `file_write` in-flight trail, captures `active_run_children()` before/after `resume/3`, asserts the tally is unchanged.
- Criterion 5 — pass: `test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason` asserts exactly one `run.failed` whose `payload.reason` equals `{resume_unsafe, s1}`.
- Criterion 6 — pass: `test_after_unsafe_resume_reconstruct_reports_failed` asserts `soma_run_resume:reconstruct/2` returns `{ok, #{terminal_status := failed}}` after the unsafe resume.
- Criterion 7 — pass: `test_second_resume_of_unsafe_failed_run_is_terminal_noop` snapshots event list and child tally after the first unsafe resume, calls `resume/3` again, asserts both unchanged and the return is `{terminal, failed}`.
- Criterion 8 — pass: `test_resume_of_terminal_run_is_noop` seeds a `run.completed` trail, asserts event list and child tally unchanged and the return is `{terminal, completed}`.
- Criterion 9 — pass: `test_resume_of_fully_committed_run_is_nothing_to_do_noop` seeds a fully-committed single-step trail, asserts event list and child tally unchanged and the return is `nothing_to_do`.
- Criterion 10 — pass: `test_resume_of_unreconstructable_trail_returns_error_noop` seeds an orphan `step.succeeded` with no `run.started`, asserts event list and child tally unchanged and the return is `{error, no_run_started_journal}`.
- Criterion 11 — pass: `test_cancelling_resumed_run_stops_worker` captures the resumed worker pid, sends `cancel` to `RunPid`, asserts the worker is dead and `run.cancelled` lands; `test_timing_out_resumed_run_lands_terminal_event` asserts `run.timeout` lands (no `run.completed`) and `Owner` receives `{run_timeout, RunId}`.
- Criterion 12 — pass: `test_tool_crash_in_resumed_step_does_not_crash_owner` resumes into a `fail`/crash step, asserts `run.failed` lands, `Owner` receives `{run_failed, RunId, _}`, and `is_process_alive(Owner)` holds.
