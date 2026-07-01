### Claude

## Verdict

Runtime shape is sane: discovery stays in the event store, boot waits until
`soma_sup` is up, and actual restart decisions still go through the existing
resume executor. The targeted tests and the full gate are green.

Do not merge as-is. The implementation now ships v0.7.5 behavior, but the
authoritative high-level docs still say v0.7.5 is future/deferred work.

## Real issues

1. Stale authoritative docs after a runtime behavior change. `README.md:37`
   still lists "v0.7.5 auto-resume on boot" under "Still open", `README.md:289`
   still lists it out of scope, `docs/design.md:305` says auto-resume on daemon
   boot remains future work, and `docs/roadmap.md:237` says v0.7.5 is deferred
   because the event store has no enumerate-run-ids query. This branch adds that
   query in `apps/soma_event_store/src/soma_event_store.erl:44` and wires boot
   resume through `apps/soma_runtime/src/soma_app.erl:9`. The code and the
   advertised runtime spec now contradict each other.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] A restarted durable event store reports a run id whose replayed trail contains `run.started` with no terminal run event.
  Artifact: `apps/soma_event_store/test/soma_event_store_persist_tests.erl:358`
  proves this with `test_restarted_disk_log_interrupted_runs_reports_started_without_terminal`.
  `rebar3 eunit --module=soma_event_store_persist_tests` passed: 11 tests, 0 failures.

- [x] The interrupted-run discovery result excludes a run id whose replayed trail contains a terminal run event.
  Artifact: `apps/soma_event_store/test/soma_event_store_persist_tests.erl:391`
  proves this with `test_restarted_disk_log_interrupted_runs_excludes_terminal_run`.
  `rebar3 eunit --module=soma_event_store_persist_tests` passed: 11 tests, 0 failures.

- [x] Booting the `soma_runtime` application with `event_store_log` resumes a between-steps interrupted run from the replayed log.
  Artifact: `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl:32`
  proves this via `application:ensure_all_started(soma_runtime)`.
  `rebar3 ct --suite apps/soma_runtime/test/soma_run_auto_resume_SUITE` passed:
  all 3 tests passed.

- [x] An auto-resumed run emits `run.resumed` for the first pending step.
  Artifact: `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl:57`
  proves the emitted `run.resumed` event carries `step_id => s2` and
  `#{first_pending_step => s2}`.
  `rebar3 ct --suite apps/soma_runtime/test/soma_run_auto_resume_SUITE` passed:
  all 3 tests passed.

- [x] Boot auto-resume fails a non-idempotent in-flight `state` step with `{resume_unsafe, StepId}`.
  Artifact: `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl:87`
  proves the boot path appends `run.failed` with `{resume_unsafe, s1}` for an
  in-flight `file_write` step.
  `rebar3 ct --suite apps/soma_runtime/test/soma_run_auto_resume_SUITE` passed:
  all 3 tests passed.

- [x] The v0.7 contract document maps auto-resume guarantees to their proving tests.
  Artifact: `apps/soma_runtime/test/soma_v0_7_contract_doc_tests.erl:58`
  checks that `docs/contracts/v0.7-test-contract.md:144` names the auto-resume
  suites and cases.
  `rebar3 eunit --module=soma_v0_7_contract_doc_tests` passed: 3 tests,
  0 failures.

Full gate:

- `rebar3 eunit` passed: 342 tests, 0 failures.
- `rebar3 ct` passed: all 354 tests passed.
