### Claude

## Verdict
approve

## Real issues

None.

## Questions

- `committed_outputs` and `terminal_status` fold left and let the last matching
  event win. A trail with two `step.succeeded` for one step id, or two terminal
  events, silently keeps the last. The design records this as deferred ("duplicate
  step ids or duplicate terminal events, can be added later"), so it's not a
  blocker. Worth a note for the resume executor that consumes this.

## Nits

- `soma_run_resume.erl` has no `-spec` on `reconstruct/2`. Every other public
  runtime entry point carries one. Cheap to add.

## Functional evidence
- Criterion 1 — pass: `soma_run:init/1` emits `run.started` with `#{payload => #{steps => Data#data.steps, ...}}` (soma_run.erl:46-48); `soma_run_resume_journal_SUITE:test_session_start_journals_steps_in_run_started` asserts `by_run/2` returns the submitted `Steps` in the payload. Green.
- Criterion 2 — pass: `durable_run_options/1` builds the allowlist map (soma_run.erl:235-245); `test_direct_run_journals_durable_options_with_correlation_id` asserts payload `run_options` equals `#{run_id, session_id, correlation_id}` and excludes `session_pid`/`event_store`. Green.
- Criterion 3 — pass: `test_restarted_disk_log_by_run_exposes_run_started_journal` boots with `event_store_log`, stops the app, restarts on the same path, asserts `by_run/2` still returns the exact journaled `#{steps, run_options}` payload. Green.
- Criterion 4 — pass: `journaled_run/1` returns `{ok, Steps, RunOptions}` (soma_run_resume.erl); `test_reconstruct_returns_journaled_steps` asserts `{ok, #{steps := Steps}}`. Green.
- Criterion 5 — pass: `test_reconstruct_returns_journaled_durable_options` asserts `{ok, #{run_options := #{run_id := RunId, session_id := SessionId, correlation_id := CorrId}}}`. Green.
- Criterion 6 — pass: `committed_outputs/1` folds `step.succeeded` into `#{StepId => Output}`; `test_reconstruct_returns_committed_outputs_by_step_id` asserts `outputs` equals `#{s1 => ..., s2 => ...}` for a two-step run. Green.
- Criterion 7 — pass: `first_uncommitted_step/2` returns the first journaled step absent from outputs; `test_reconstruct_returns_first_uncommitted_step` asserts `next_step` is the journaled `s2` map when `s1` committed. Green.
- Criterion 8 — pass: `terminal_status/2` maps each terminal event to its atom; `test_reconstruct_returns_terminal_status` asserts `completed`/`failed`/`timeout`/`cancelled` and `undefined` for no terminal event. Green.
- Criterion 9 — pass: `journaled_run/1` returns `error` on a `run.started` payload without list `steps` + map `run_options`; `test_reconstruct_rejects_missing_run_started_journal` asserts `{error, no_run_started_journal}` for a `payload => #{}` trail. Green.
- Criterion 10 — pass: `unknown_committed_step/2` flags a committed step id absent from the journal; `test_reconstruct_rejects_unknown_committed_step` asserts `{error, {unknown_committed_step, s2}}`. Green.
- Criterion 11 — pass: `reconstruct/2` only calls `by_run/2`; `test_reconstruct_does_not_append_events` asserts `soma_event_store:all/1` is byte-for-byte equal before and after. Green.
- Criterion 12 — pass: `test_reconstruct_does_not_start_run_children` asserts `supervisor:count_children(soma_run_sup)` is unchanged across the call. Green.
- Criterion 13 — pass: `docs/contracts/v0.7-test-contract.md` maps all 12 guarantees to their cases (table at lines 70-83); `soma_v0_7_contract_doc_tests:test_doc_names_resume_journal_suite_and_cases` asserts the doc names the suite and each case. Green. Full gate: EUnit 227, CT 275, 0 failures.
