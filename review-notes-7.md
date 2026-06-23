### Claude

## Verdict
changes-requested

## Real issues

- `run.timeout` and `run.cancelled` drop `step_id` and `tool_call_id`.
  `soma_run.erl` emits both with an empty extra map:
  `emit(Data, <<"run.timeout">>, #{})` and `emit(Data, <<"run.cancelled">>, #{})`.
  The store defaults the missing keys to `undefined`. The run has both values in
  hand at that point — `Data#data.tool_call_id` and `maps:get(id, Data#data.current)`
  — and the error path already passes them on `tool.failed`/`step.failed`. So
  these two terminal events are the only ones that throw away the step and
  tool-call identity. A consumer reading a timed-out or cancelled run's trail
  cannot tell which step or which tool call ended it. The design said the
  opposite: "The run should still pass the real `step_id` and `tool_call_id` on
  the failure events ... so those fields are not `undefined`." The
  criterion-11 test only asserts `maps:is_key/2`, so it passes a trail with
  `undefined` step_id — the test was shaped not to catch this. Pass the real
  `step_id` and `tool_call_id` on both events, and tighten the test to assert
  they are not `undefined`.

## Questions

- `cancel` has no clause in `executing/3`. The run handles `cancel` only in
  `waiting_tool`. Today the run never dwells in `executing` with an external
  message pending — `init` and every step boundary insert a
  `{next_event, internal, next_step}`, which `gen_statem` dequeues ahead of the
  async `cancel` info message, so the run is always in `waiting_tool` by the
  time a forwarded `cancel` is read. It works now. The design said cancel would
  be handled in both `executing` and `waiting_tool`; the code dropped the
  `executing` clause. If a future change ever lets the run sit in `executing`
  while a `cancel` is queued, the `gen_statem` takes an unmatched-event exit.
  Worth a one-line catch-all in `executing` to keep it safe, or a comment
  saying the ordering guarantee is load-bearing.

## Nits

- `soma_tool_call:run/2` runs `Module:invoke/2` with no try/catch — correct, the
  crash is meant to reach the run's monitor as `'DOWN'`. The module's `@doc`
  still says only "handles the `{ok, Output}' return," which now undersells it:
  the worker also carries `{error, _}` returns and dies on raises by design.
  Update the doc.
- `index_of/2` in the test suite has no clause for the empty list; it crashes
  with a function-clause error if the event type is absent. Harmless when the
  event is present, but a missing-event failure would read as a confusing crash
  rather than a clear assertion. Minor.

## Functional evidence
- Criterion 1 — pass: `test_error_return_reaches_failed_not_completed` asserts `run.failed` present, `run.completed` absent, and `get_status` reports `failed`. Green in full `rebar3 ct` run (27/27).
- Criterion 2 — pass: `test_error_trail_tool_step_run_failed_in_order` asserts `index_of(tool.failed) < index_of(step.failed) < index_of(run.failed)` in the run-scoped trail. Green.
- Criterion 3 — pass: `test_tool_crash_reaches_failed` runs `fail` in crash mode; the worker raises, the run's monitor `'DOWN'` clause drives it to `failed`. Asserts `run.failed` present, `run.completed` absent. Green.
- Criterion 4 — pass: `test_session_alive_after_tool_crash` asserts `is_process_alive(SessionPid)` after the crashed run reaches `failed`. Green.
- Criterion 5 — pass: `test_overrun_reaches_timeout_records_run_timeout` runs `sleep` ms=1000 with `timeout_ms=50`; asserts `run.timeout` present, `run.completed` absent. Green.
- Criterion 6 — pass: `test_hung_worker_dead_after_timeout` reads the worker pid from `tool.started`, waits for `run.timeout`, asserts `is_process_alive(WorkerPid) =:= false`. Green.
- Criterion 7 — pass: `test_cancel_run_reaches_cancelled_records_event` sends `SessionPid ! {cancel_run, RunId}`; asserts `run.cancelled` present, `run.completed` absent. Green.
- Criterion 8 — pass: `test_worker_dead_after_cancel` reads the worker pid from `tool.started`, cancels, asserts `is_process_alive(WorkerPid) =:= false`. Green.
- Criterion 9 — pass: `test_session_alive_after_cancel` asserts `is_process_alive(SessionPid)` after the cancelled run reaches `cancelled`. Green.
- Criterion 10 — pass: `test_session_runs_new_run_after_failed`, `_after_timeout`, `_after_cancelled` each run a terminal run, then a fresh `echo` run on the same session that reaches `run.completed` and reports `completed`. All three green.
- Criterion 11 — pass with caveat: `test_failure_events_carry_eight_mandatory_fields` asserts all eight keys present on `tool.failed`, `step.failed`, `run.failed`, `run.cancelled`, `run.timeout`. Keys present — but `run.timeout` and `run.cancelled` carry `undefined` for `step_id`/`tool_call_id` (see Real issues). The test only checks key presence, not value.
- Criterion 12 — pass: `test_get_status_reports_terminal_outcome` asserts `get_status` reports `failed`, `timeout`, `cancelled` for three distinct runs, never `completed`. Green.
