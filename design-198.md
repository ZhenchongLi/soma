# [cc] v0.7.5 auto-resume on boot

## Current state

Manual resume is already built.
`soma_run_resume:reconstruct/2` reads a run trail through `soma_event_store:by_run/2`.
`soma_run_resume_plan:plan/2` classifies the replay result as resume, unsafe, terminal, nothing to do, or error.
`soma_run_resume_executor:resume/3` turns that plan into either a fresh `soma_run` child or a terminal `run.failed` with `{resume_unsafe, StepId}`.

The durable event store already replays a `disk_log` into memory at boot.
It exposes `all/1`, `by_run/2`, `by_session/2`, and `by_correlation/2`.
It does not expose the missing query: "which run ids have `run.started` and no terminal run event?"

The runtime application callback only starts `soma_sup`.
`soma_sup` starts `soma_event_store`, `soma_tool_registry`, `soma_session_sup`, and `soma_run_sup`.
Nothing calls the resume executor after those children are up.

That means a durable log can contain enough data to resume, but boot does not discover the run id.
The only way to resume today is an explicit call to `soma_run_resume_executor:resume/3`.

## Approach

Add an event-store discovery query named `soma_event_store:interrupted_runs/1`.
It walks the replayed in-memory event list and returns unique run ids whose trail contains `run.started` and no terminal run event.
The terminal event types are `run.completed`, `run.failed`, `run.timeout`, and `run.cancelled`.
The query stays inside `soma_event_store` because boot should not scan raw event lists in each caller.
It also keeps the durable replay cache as the read model for resume discovery.

Add a small runtime coordinator module, `soma_run_auto_resume`.
It should expose one public entry point, `resume_interrupted/1`.
That function calls `soma_event_store:interrupted_runs(StorePid)` and then calls `soma_run_resume_executor:resume(RunId, undefined, StorePid)` for each returned run id.
The owner is `undefined` because v0.7.5 does not reconstruct sessions or actors.
The resumed run still keeps the durable `session_id` and `correlation_id` from `run_options`, so its event trail remains tied to the original ids.

Call the coordinator from `soma_app:start/2` after `soma_sup:start_link()` succeeds and only when `event_store_log` is set.
At that point the event store has replayed the log and `soma_run_sup` is available.
The application should still return `{ok, SupPid}` after running the scan.
An unsafe in-flight `state` step is a run-level failure written by the executor, not an application boot failure.

Do not change `soma_run`'s sequential executor.
Do not add actor task-state recovery.
Do not add a per-tool resume policy.

## Acceptance criteria -> tests

### Criterion 1 — restarted store reports an interrupted run

- Call chain: `soma_app:start/2` -> `soma_sup:start_link/0` -> `soma_event_store:start_link(#{log := Path})` -> `replay_log/1` -> `soma_event_store:interrupted_runs/1`
- Test entry: `soma_event_store:start_link/1` because this criterion proves the event-store query over a replayed durable log, not runtime boot orchestration.
- Test: `test_restarted_disk_log_interrupted_runs_reports_started_without_terminal` in `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 2 — discovery excludes terminal runs

- Call chain: `soma_app:start/2` -> `soma_sup:start_link/0` -> `soma_event_store:start_link(#{log := Path})` -> `replay_log/1` -> `soma_event_store:interrupted_runs/1`
- Test entry: `soma_event_store:start_link/1` because this criterion proves the event-store query over a replayed durable log, not runtime boot orchestration.
- Test: `test_restarted_disk_log_interrupted_runs_excludes_terminal_run` in `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 3 — boot resumes a between-steps interrupted run

- Call chain: `application:ensure_all_started(soma_runtime)` -> `soma_app:start/2` -> `soma_sup:start_link/0` -> `soma_run_auto_resume:resume_interrupted/1` -> `soma_event_store:interrupted_runs/1` -> `soma_run_resume_executor:resume/3` -> `soma_run_sup:start_run/1` -> `soma_run:init/1`
- Test entry: `application:ensure_all_started(soma_runtime)`
- Test: `test_boot_with_event_store_log_resumes_between_steps_interrupted_run` in `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl`

### Criterion 4 — auto-resumed run emits `run.resumed`

- Call chain: `application:ensure_all_started(soma_runtime)` -> `soma_app:start/2` -> `soma_sup:start_link/0` -> `soma_run_auto_resume:resume_interrupted/1` -> `soma_run_resume_executor:resume/3` -> `soma_run_sup:start_run/1` -> `soma_run:init/1` -> `soma_run:emit/3`
- Test entry: `application:ensure_all_started(soma_runtime)`
- Test: `test_boot_auto_resume_emits_run_resumed_for_first_pending_step` in `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl`

### Criterion 5 — boot fails unsafe in-flight `state` step

- Call chain: `application:ensure_all_started(soma_runtime)` -> `soma_app:start/2` -> `soma_sup:start_link/0` -> `soma_run_auto_resume:resume_interrupted/1` -> `soma_event_store:interrupted_runs/1` -> `soma_run_resume_executor:resume/3` -> `soma_run_resume_plan:plan/2` -> `soma_event_store:append/2`
- Test entry: `application:ensure_all_started(soma_runtime)`
- Test: `test_boot_auto_resume_fails_unsafe_in_flight_state_step` in `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl`

### Criterion 6 — v0.7 contract maps auto-resume proofs

- Call chain: none (direct source-file read)
- Test entry: `soma_v0_7_contract_doc_tests`
- Test: `test_doc_names_auto_resume_suite_and_cases` in `apps/soma_runtime/test/soma_v0_7_contract_doc_tests.erl`

## Risks & trade-offs

Boot auto-resume has no live session or actor owner.
That is intentional for this slice.
The run writes durable terminal events, but no old session state is rebuilt.

The discovery query is a linear scan over replayed events.
That matches the current event-store shape and the roadmap's note that log indexes are later work.

Calling resume during application start can start run children before `ensure_all_started/1` returns.
That makes boot behavior easy to test and keeps all resume work under the existing runtime tree.
It also means a very large interrupted set can add boot latency until indexing or bounded task queues exist.
