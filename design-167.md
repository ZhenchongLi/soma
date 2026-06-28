# v0.7.4: resume executor + manual resume/3 — continue a run or land it fail-safe

## Current state

Three pieces of the resume path exist, and none of them restarts a run.

`soma_run_resume:reconstruct/2` reads the durable trail for a run id and rebuilds a snapshot: the journaled `steps`, the `run_options`, the committed `outputs` keyed by step id, the first uncommitted step as `next_step`, and the terminal status if a terminal event landed. It is read-only.

`soma_run_resume_plan:plan/2` reconstructs that snapshot and turns it into a verdict. It returns one of five shapes:

- `{resume, #{steps, pending, outputs, run_options}}` — there is uncommitted work and the next step is safe to (re-)run.
- `{unsafe, StepId}` — the next step was in flight (a `tool.started` landed, no `step.succeeded`) and its tool is a non-idempotent `state` effect, so re-running it could repeat an irreversible write.
- `{terminal, Status}` — a terminal event is already on the trail.
- `nothing_to_do` — every journaled step is committed and no terminal event landed.
- `{error, Reason}` — the trail has no usable journal, or commits a step the journal never declared.

`soma_run` already knows how to start mid-list (v0.7.2). When `start_link/1` is given a `pending` opt, it opens with `run.resumed` instead of `run.started`, seeds `outputs` so a pending step's `from_step` into a committed step resolves, and walks only the `pending` suffix. So the machinery to *continue* a run exists, but nothing calls it from a verdict.

What is missing is the actor that reads a verdict and acts: start a fresh `soma_run` child for `{resume, _}`, land a terminal `run.failed` for `{unsafe, _}`, and do nothing for `{terminal, _}` / `nothing_to_do` / `{error, _}`. There is no public `resume` entry on the runtime at all today (there is no `soma_runtime.erl` module yet).

## Approach

Add `resume/3` to a new module `soma_run_resume_executor` in `apps/soma_runtime/src/`. The open question in the issue leaves the home of `resume/3` to us as long as it lives in the runtime app and the one-way dependency holds. A separate executor module keeps the read-only plan/reconstruct modules read-only and puts the one function that actually starts a run and appends an event in its own place.

`resume(RunId, Owner, Store)` calls `soma_run_resume_plan:plan(Store, RunId)` and branches on the verdict:

- `{resume, #{steps, pending, outputs, run_options}}` → start a fresh `soma_run` child under `soma_run_sup` with those four fields plus `run_id` (from `run_options`), `event_store => Store`, and `session_pid => Owner`. Return `{ok, RunPid}`. This is a normal supervised child, so cancellation, timeout, and crash isolation are the run's existing behavior, not anything re-implemented here.
- `{unsafe, StepId}` → start no run. Append one terminal `run.failed` event for the run with reason `{resume_unsafe, StepId}`. Return `{unsafe, StepId}`.
- `{terminal, Status}` → start no run, append no event. Return `{terminal, Status}`.
- `nothing_to_do` → start no run, append no event. Return `nothing_to_do`.
- `{error, Reason}` → start no run, append no event. Return `{error, Reason}`.

Why `Owner` maps to the run's `session_pid`: a `soma_run` reports `run_completed` / `run_failed` / `run_timeout` / `run_cancelled` to whatever pid it holds as `session_pid`. The resumed run is owned by `Owner`, so `Owner` is exactly the pid that should receive those messages and the pid whose liveness a tool crash must not threaten. The issue's `Owner` is the v0.7.2 seam's `session_pid` under a caller-facing name.

Why the unsafe `run.failed` is appended by the executor and not by a `soma_run`: an unsafe verdict starts no run, so there is no `soma_run` process to emit the terminal event. The executor appends it directly, the same shape `soma_run` would emit (`event_type => <<"run.failed">>`, `payload => #{reason => ...}`), so `soma_run_resume:reconstruct/2` reads the run's `terminal_status` as `failed` afterward. This is the one place the executor writes to the store.

The unsafe path is idempotent by construction, not by a guard the executor adds. After the first unsafe resume, the trail carries a `run.failed`, so the next `plan/2` reconstructs `terminal_status => failed` and classifies it `{terminal, failed}` before it ever looks at `next_step`. So a second `resume/3` of an already-unsafe-failed run takes the `{terminal, _}` branch: no new run, no new event. The executor does not need to remember it already failed the run; the trail remembers.

Three opts a normal start needs are not in the seam payload: `run_id`, `event_store`, `session_pid`. `run_id` comes from `run_options` (it is always present there per the journal allowlist). `event_store` is `Store`. `session_pid` is `Owner`. The executor maps those in; `correlation_id` and `session_id` are left to whatever `run_options` carried.

Scope stays locked to the issue: no auto-scan on boot, no `resume/1` convenience, no per-tool resume policy.

## Acceptance criteria → tests

The natural home for these is a new CT suite `soma_run_resume_executor_SUITE` in `apps/soma_runtime/test/`, mirroring `soma_run_resume_plan_SUITE` — it boots `soma_runtime`, takes the live `soma_event_store` pid, seeds a durable trail by appending events, then drives `resume/3`. The resumed-run criteria need a real live `Owner` pid that survives, so those cases spawn a small collector process (or use `self()`) as `Owner` and assert on the messages it receives and on its survival.

### Criterion 1 — between-steps resume starts a fresh child that completes
- Call chain: seed trail (`run.started` for `[s1, s2]` + `step.succeeded` for s1) → `soma_run_resume_executor:resume/3` → `soma_run_resume_plan:plan/2` returns `{resume, _}` → `soma_run_sup:start_run/1` → `soma_run:init/1` walks the `pending` suffix to `run.completed`
- Test entry: `soma_run_resume_executor:resume/3` (the full chain runs, no layer bypassed)
- Test: `test_between_steps_resume_starts_fresh_child_that_completes` in `apps/soma_runtime/test/soma_run_resume_executor_SUITE.erl` — asserts the returned `{ok, RunPid}` is a distinct pid from any prior run, that `RunPid` is a child of `soma_run_sup`, and that the trail reaches `run.completed`.

### Criterion 2 — Owner gets run_completed with merged outputs
- Call chain: `resume/3` → `soma_run_sup:start_run/1` → resumed `soma_run` finishes its pending steps → `notify_session/1` sends `{run_completed, RunId, Outputs}` to `session_pid` (= `Owner`)
- Test entry: `resume/3`, with `Owner` set to a live collector pid that waits for the message
- Test: `test_between_steps_resume_sends_owner_completed_with_merged_outputs` in the same suite — seeds s1 committed, resumes, and asserts `Owner` receives `{run_completed, RunId, Outputs}` where `Outputs` holds both the seeded s1 output and the freshly-run s2 output.

### Criterion 3 — safe in-flight step re-runs in its own worker and completes
- Call chain: seed trail (`run.started` for a single `file_read` step + a `tool.started` for it, no `step.succeeded`) → `resume/3` → `plan/2` returns `{resume, _}` (the step is in flight but `file_read` is reader/idempotent, so safe) → `soma_run_sup:start_run/1` → resumed `soma_run` runs the step in a `soma_tool_call` worker to `run.completed`
- Test entry: `resume/3`
- Test: `test_in_flight_safe_step_reruns_in_own_worker_and_completes` in the same suite — asserts the trail after resume carries a `tool.started` with a real `tool_call_pid` distinct from the run pid, and reaches `run.completed`. (The step reads a file the test seeds first so the read succeeds.)

### Criterion 4 — unsafe in-flight step starts no run child
- Call chain: seed trail (`run.started` for a single `file_write` step + a `tool.started` for it) → `resume/3` → `plan/2` returns `{unsafe, s1}` → executor appends `run.failed`, starts nothing
- Test entry: `resume/3`
- Test: `test_unsafe_in_flight_resume_starts_no_run` in the same suite — captures `supervisor:count_children(soma_run_sup)` before and after `resume/3` and asserts the child tally is unchanged.

### Criterion 5 — unsafe resume appends run.failed with {resume_unsafe, StepId}
- Call chain: same seed as criterion 4 → `resume/3` → executor appends the terminal `run.failed`
- Test entry: `resume/3`
- Test: `test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason` in the same suite — asserts the run's trail gains exactly one `run.failed` whose `payload.reason` is `{resume_unsafe, s1}`.

### Criterion 6 — after unsafe resume, reconstruct reports terminal_status failed
- Call chain: `resume/3` (unsafe) appends `run.failed` → `soma_run_resume:reconstruct/2` reads the trail
- Test entry: `soma_run_resume:reconstruct/2`, called after `resume/3`, because this criterion checks what a later reader sees, not a layer of `resume/3` itself
- Test: `test_after_unsafe_resume_reconstruct_reports_failed` in the same suite — asserts `reconstruct/2` returns `{ok, #{terminal_status := failed}}`.

### Criterion 7 — second resume of an already-unsafe-failed run is a no-op terminal verdict
- Call chain: first `resume/3` (unsafe) appends `run.failed` → second `resume/3` → `plan/2` reconstructs `terminal_status => failed` → `{terminal, failed}` → executor starts nothing, appends nothing
- Test entry: the second `resume/3`
- Test: `test_second_resume_of_unsafe_failed_run_is_terminal_noop` in the same suite — after the first resume, snapshots the run's event list and the `soma_run_sup` child tally, calls `resume/3` again, and asserts the event list is byte-for-byte unchanged, the child tally is unchanged, and the return is `{terminal, failed}`.

### Criterion 8 — resume of an already-terminal run is a no-op terminal verdict
- Call chain: seed a trail with `run.started` + `step.succeeded` + `run.completed` → `resume/3` → `plan/2` returns `{terminal, completed}` → executor starts nothing, appends nothing
- Test entry: `resume/3`
- Test: `test_resume_of_terminal_run_is_noop` in the same suite — asserts the event list and child tally are unchanged and the return is `{terminal, completed}`.

### Criterion 9 — resume of a fully-committed run (nothing_to_do) is a no-op
- Call chain: seed a single-step trail, that step committed, no terminal event → `resume/3` → `plan/2` returns `nothing_to_do` → executor starts nothing, appends nothing
- Test entry: `resume/3`
- Test: `test_resume_of_fully_committed_run_is_nothing_to_do_noop` in the same suite — asserts the event list and child tally are unchanged and the return is `nothing_to_do`.

### Criterion 10 — resume of a trail that reconstructs to {error, _} is a no-op that returns the error
- Call chain: seed an orphan `step.succeeded` with no `run.started` → `resume/3` → `plan/2` propagates `{error, no_run_started_journal}` → executor starts nothing, appends nothing
- Test entry: `resume/3`
- Test: `test_resume_of_unreconstructable_trail_returns_error_noop` in the same suite — asserts the event list and child tally are unchanged and the return is `{error, no_run_started_journal}`.

### Criterion 11 — cancelling or timing out a resumed run is real
- Call chain: resume a between-steps run whose pending step sleeps (e.g. a `sleep` step) → resumed `soma_run` is in `waiting_tool` with a live worker → send `cancel` to the run pid → it kills the worker, emits `run.cancelled`, and notifies `Owner`; a separate case gives the pending step a short `timeout_ms` and lets the timer fire
- Test entry: `resume/3` for the start, then a direct message to the returned `RunPid` for cancel (this is how a real owner cancels a run today)
- Test: `test_cancelling_resumed_run_stops_worker` and `test_timing_out_resumed_run_lands_terminal_event` in the same suite — the cancel case captures the worker pid from `tool.started`, sends `cancel`, and asserts the worker is dead and a `run.cancelled` lands; the timeout case asserts a `run.timeout` lands and `Owner` receives `{run_timeout, RunId}`.

### Criterion 12 — a tool crash inside a resumed step is run data, not an Owner crash
- Call chain: resume a between-steps run whose pending step uses the `fail` tool in crash mode → resumed `soma_run` spawns the worker, the worker crashes, the monitor delivers `'DOWN'`, the run records the failure trail and notifies `Owner` with `{run_failed, RunId, Reason}`
- Test entry: `resume/3` with `Owner` a live collector pid
- Test: `test_tool_crash_in_resumed_step_does_not_crash_owner` in the same suite — asserts a `run.failed` lands for the run, `Owner` receives `{run_failed, RunId, _}`, and `Owner` is still alive (`is_process_alive/1`) afterward.

## Risks & trade-offs

The executor writes one event type to the store (`run.failed` on the unsafe path) while the plan and reconstruct modules stay read-only. That split is deliberate, but it means "the resume code is read-only" stops being true at this layer — a reader of the trail can no longer assume every `run.failed` came from a `soma_run`. The reason tag `{resume_unsafe, StepId}` is what distinguishes an executor-written terminal from a run-written one, so anything that later wants to tell them apart keys on the reason, not the event type.

`Owner` is taken as a raw pid with no liveness check before the run starts. If a caller passes a dead pid, the resumed run still starts and runs to completion; its `notify_session` send to a dead pid is a silent no-op (a bare `!` to a dead pid does not error). That is the same contract a normal `soma_run` has with its `session_pid`, so this is consistent, not a new hole — but it does mean `resume/3` cannot tell a caller "your owner was already gone." The v0.7.5 convenience that defaults `Owner` to a long-lived session is where that stops mattering.

The idempotency of a repeated unsafe resume rests entirely on the terminal event being on the trail before the second call. If two `resume/3` calls for the same unsafe run race (same store, truly concurrent), both could read a pre-terminal trail and both append a `run.failed`. This slice takes `Store` and `Owner` explicitly and is driven manually, so a concurrent double-resume is not a path the criteria exercise; the v0.7.5 auto-scan is where serialization would need a real answer.
