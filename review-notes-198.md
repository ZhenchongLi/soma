### Claude

## Verdict

Reviewed the current branch diff against `origin/main`.

This is the boring version of correctness: the event store owns discovery, boot
only coordinates after `soma_sup` is alive, and the dangerous decision still goes
through the existing resume planner/executor. The prior stale-doc problem is
fixed in this head. Full gate is green.

## Real issues

None found.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] A restarted durable event store reports a run id whose replayed trail contains `run.started` with no terminal run event.
  Artifact: `apps/soma_event_store/test/soma_event_store_persist_tests.erl:358`
  seeds a durable log, restarts the store, calls
  `soma_event_store:interrupted_runs/1`, and asserts `[interrupted_run]`.

- [x] The interrupted-run discovery result excludes a run id whose replayed trail contains a terminal run event.
  Artifact: `apps/soma_event_store/test/soma_event_store_persist_tests.erl:391`
  seeds `terminal_run` with `run.failed`, restarts the store, and asserts only
  `[interrupted_run]` is reported.

- [x] Booting the `soma_runtime` application with `event_store_log` resumes a between-steps interrupted run from the replayed log.
  Artifact: `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl:32`
  sets `event_store_log`, boots with `application:ensure_all_started/1`, waits
  for `run.completed`, and verifies the pending step output.

- [x] An auto-resumed run emits `run.resumed` for the first pending step.
  Artifact: `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl:57`
  waits for `run.resumed` and asserts `step_id => s2` plus
  `#{first_pending_step => s2}`.

- [x] Boot auto-resume fails a non-idempotent in-flight `state` step with `{resume_unsafe, StepId}`.
  Artifact: `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl:87`
  seeds an in-flight `file_write` step and verifies boot appends `run.failed`
  with `{resume_unsafe, s1}` on the original run/session trail.

- [x] The v0.7 contract document maps auto-resume guarantees to their proving tests.
  Artifact: `docs/contracts/v0.7-test-contract.md:144` maps the v0.7.5
  guarantees to suites/cases, and
  `apps/soma_runtime/test/soma_v0_7_contract_doc_tests.erl:58` proves the doc
  names the auto-resume suites and cases.

Verification run in this worktree:

- `rebar3 eunit --module=soma_event_store_persist_tests` passed: 11 tests, 0 failures.
- `rebar3 eunit --module=soma_v0_7_contract_doc_tests` passed: 3 tests, 0 failures.
- `rebar3 ct --suite apps/soma_runtime/test/soma_run_auto_resume_SUITE` passed: all 3 tests passed.
- `rebar3 eunit` passed: 342 tests, 0 failures.
- `rebar3 ct` passed: all 354 tests passed.
