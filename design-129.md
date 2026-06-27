## Current state

- `README.md` defines the runtime contract: a run is a supervised OTP process
  tree, `soma_agent_session` accepts run requests but never executes tools, and
  `soma_run` owns the step cursor, outputs, active worker, cancellation, and
  event emission.
- `soma_agent_session:start_run/2` currently emits `run.accepted` and starts
  `soma_run` under `soma_run_sup` with `run_id`, `session_id`, `session_pid`,
  `event_store`, and `steps`.
- `soma_run:init/1` currently copies those opts into its state and emits
  `run.started` with an empty payload. The submitted step list is therefore not
  durable unless it can be recovered from another source, which a restarted node
  does not have.
- Direct run owners already exist outside `soma_agent_session`: `soma_actor` and
  `soma_cli_task_registry` start `soma_run` through `soma_run_sup` with
  `correlation_id`. The durable resume-safe values in that path are
  `run_id`, `session_id`, and `correlation_id`; process-local values such as
  `session_pid`, `event_store`, pids, monitors, timers, and OS pids are not
  resume-safe.
- `step.succeeded` already records the committed output in
  `payload => #{output => Output}`. Failed, timed-out, and cancelled steps do not
  commit an output.
- `soma_event_store` normalizes every event, writes that normalized map to the
  opt-in `disk_log`, rebuilds its in-memory index from the log on restart, and
  serves `by_run/2` in append order. This makes the event trail the right source
  of truth for a first read-only resume reconstruction slice.
- No resume reconstruction API exists today, and this issue does not start a
  resumed run, re-run tools, decide in-flight idempotency, or reconstruct actor
  task state.

## Approach

- Journal resume inputs at the source of truth: `soma_run:init/1` should emit
  `run.started` with a payload shaped as
  `#{steps => Steps, run_options => DurableRunOptions}`.
- `DurableRunOptions` should contain only resume-safe metadata accepted by
  `soma_run`: `run_id` always, `session_id` when present, and `correlation_id`
  when present. It must not include `session_pid`, `event_store`, worker pids,
  monitor refs, timers, OS pids, or any provider secret.
- This single `soma_run` change covers both production session starts and direct
  run starts, because both paths already pass the canonical step list into
  `soma_run`.
- Add a runtime module, proposed as `soma_run_resume`, with
  `reconstruct(StorePid, RunId)`.
- `reconstruct/2` should be read-only. It should call
  `soma_event_store:by_run(StorePid, RunId)`, reconstruct from the returned
  event list, and never call `append/2`, `soma_run_sup:start_run/1`, or any tool
  execution path.
- Proposed success return:
  `#{run_id => RunId, steps => Steps, run_options => DurableRunOptions,
     outputs => OutputsByStepId, next_step => NextStep,
     terminal_status => TerminalStatus}` inside `{ok, Map}`.
- `outputs` should be built only from `step.succeeded` events by reading
  `step_id` and `payload.output`. The keys are the committed step ids and the
  values are the committed outputs.
- `next_step` should be the first journaled step whose id is not present in
  `outputs`. If every journaled step has committed, return `undefined`. This is
  independent of `terminal_status`; callers must inspect the terminal status
  before deciding whether a future resume is allowed.
- `terminal_status` should be `completed`, `failed`, `timeout`, or `cancelled`
  when a matching terminal event is present, and `undefined` when no terminal
  event is present.
- Reject `{error, no_run_started_journal}` when the run trail has no usable
  `run.started` journal with a list-valued `steps` payload and a map-valued
  `run_options` payload.
- Reject `{error, {unknown_committed_step, StepId}}` when a `step.succeeded`
  event commits output for a `StepId` that is absent from the journaled step ids.
  This protects resume from trusting an event trail that cannot be reconciled
  with its own journal.
- Keep the reconstruction layer inside `apps/soma_runtime`. It can depend on
  `soma_event_store`, but `soma_event_store` should stay generic and should not
  learn runtime-specific run semantics.
- Add `docs/contracts/v0.7-test-contract.md` for this slice. It should follow
  the existing contract-doc style and state that v0.7.1 builds a journal and
  reconstruction API only, not execution of resumed runs.

## Acceptance criteria -> tests

| Acceptance criterion | Concrete test case | Intended implementation surface |
| --- | --- | --- |
| A production run started through `soma_agent_session:start_run/2` records the submitted steps in the `run.started` payload. | `soma_run_resume_journal_SUITE:test_session_start_journals_steps_in_run_started` | Start `soma_runtime`, call `soma_agent_session:start_run/2` with a non-empty step list, read `soma_event_store:by_run/2`, and assert the `run.started` event payload has `steps = Steps`. Implement in `soma_run:init/1` by passing the journal payload to `emit/3`. |
| A direct `soma_run` start with `correlation_id` records durable run options in the `run.started` payload. | `soma_run_resume_journal_SUITE:test_direct_run_journals_durable_options_with_correlation_id` | Start a run directly through `soma_run_sup:start_run/1` with `run_id`, `session_id`, `correlation_id`, and `steps`; assert `payload.run_options` contains those three values and excludes `session_pid` and `event_store`. Implement with a private durable-options builder in `soma_run`. |
| A restarted `disk_log` event store exposes the journaled `run.started` payload through `soma_event_store:by_run/2`. | `soma_run_resume_journal_SUITE:test_restarted_disk_log_by_run_exposes_run_started_journal` | Boot `soma_runtime` with `event_store_log`, run a session-started run, stop the app, restart with the same path, and assert `by_run/2` still returns `run.started` with the journaled payload. No new event-store API is needed. |
| The resume reconstruction API returns the journaled steps for a run. | `soma_run_resume_journal_SUITE:test_reconstruct_returns_journaled_steps` | Call `soma_run_resume:reconstruct(StorePid, RunId)` over a run trail and assert `{ok, #{steps := Steps}}`. |
| The resume reconstruction API returns the journaled durable run options for a run. | `soma_run_resume_journal_SUITE:test_reconstruct_returns_journaled_durable_options` | Reconstruct a direct run with `correlation_id` and assert `{ok, #{run_options := #{run_id := RunId, session_id := SessionId, correlation_id := CorrId}}}`. |
| The resume reconstruction API returns committed step outputs keyed by step id. | `soma_run_resume_journal_SUITE:test_reconstruct_returns_committed_outputs_by_step_id` | Use a two-step run with only successful committed outputs, reconstruct, and assert `outputs` equals the `step.succeeded` outputs keyed by `s1`, `s2`, etc. |
| The resume reconstruction API returns the first uncommitted journal step as `next_step`. | `soma_run_resume_journal_SUITE:test_reconstruct_returns_first_uncommitted_step` | Append or produce a trail where `s1` committed and `s2` is still uncommitted; reconstruct and assert `next_step` is the journaled `s2` step map. |
| The resume reconstruction API returns the terminal run status when a terminal event is present. | `soma_run_resume_journal_SUITE:test_reconstruct_returns_terminal_status` | Drive or synthesize trails ending in each terminal event type and assert the mapped atom: `completed`, `failed`, `timeout`, `cancelled`. |
| The resume reconstruction API rejects a trail with no usable `run.started` journal. | `soma_run_resume_journal_SUITE:test_reconstruct_rejects_missing_run_started_journal` | Append a run trail without a journaled `run.started`, or with malformed `payload`, and assert `{error, no_run_started_journal}`. |
| The resume reconstruction API rejects a trail whose committed step id is absent from the journaled steps. | `soma_run_resume_journal_SUITE:test_reconstruct_rejects_unknown_committed_step` | Append `run.started` with journaled `[s1]`, then append `step.succeeded` for `s2`, and assert `{error, {unknown_committed_step, s2}}`. |
| The resume reconstruction API leaves the event store unchanged during reconstruction. | `soma_run_resume_journal_SUITE:test_reconstruct_does_not_append_events` | Capture `soma_event_store:all(StorePid)` before and after `reconstruct/2` and assert exact equality. |
| The resume reconstruction API leaves `soma_run_sup` child count unchanged during reconstruction. | `soma_run_resume_journal_SUITE:test_reconstruct_does_not_start_run_children` | Capture `supervisor:count_children(soma_run_sup)` or the run child pids before and after `reconstruct/2` and assert exact equality. |
| `docs/contracts/v0.7-test-contract.md` maps each resume journal guarantee to a test case. | `soma_v0_7_contract_doc_tests:test_doc_names_resume_journal_suite_and_cases` | Add the contract doc and a small EUnit doc test that asserts the doc names `soma_run_resume_journal_SUITE` and each case listed above. |

## Risks & trade-offs

- Journaling the submitted step list duplicates data in the event stream. That
  is intentional for restart safety: the durable event trail must be sufficient
  to reconstruct progress without a live session process.
- Step args can include file paths and user-provided values. This issue should
  not add secret-bearing fields to steps, and it must not journal process-local
  or provider-secret values. The durable option builder should be allowlist-based.
- `next_step` is a progress marker, not a permission to resume. A failed,
  timed-out, or cancelled trail may still have an uncommitted step; this slice
  only reports the state and leaves policy for a later resume executor.
- The reconstruction API should tolerate in-progress trails but should reject
  structurally inconsistent trails where committed outputs do not match the
  journal. Additional validations, such as duplicate step ids or duplicate
  terminal events, can be added later if resume execution needs them.
- Keeping reconstruction in `soma_runtime` avoids putting run-specific semantics
  into the generic event store, at the cost of one more runtime module.
- `README.md` currently lists persistent run resume as future work. For this
  slice, the contract doc should make clear that only journaling and read-only
  reconstruction are delivered; starting resumed runs remains out of scope.
