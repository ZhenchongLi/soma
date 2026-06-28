# v0.7.2: soma_run resume seam — start mid-list from a reconstructed snapshot

## Current state

`soma_run:init/1` always starts a run from step 0. It reads one `steps` opt and
uses it for two things at once:

```erlang
steps   = maps:get(steps, Opts, []),
pending = maps:get(steps, Opts, [])
```

`steps` is the full journaled list (the run's identity, written into the
`run.started` payload). `pending` is the live cursor the state machine walks
down as each step succeeds. Today they always start equal, and `outputs` always
starts `#{}`. So a run can only ever re-run from the first step — there is no way
to hand it the outputs of steps that already committed and tell it to pick up in
the middle.

`soma_run_resume:reconstruct/2` already produces exactly the snapshot we'd want
to feed back in: `#{steps, run_options, outputs, next_step, terminal_status}`,
where `outputs` is the committed `step.succeeded` outputs keyed by step id. But
nothing consumes it as a run start — v0.7.1 was read-only. This slice closes the
first half of that gap: let `soma_run` accept the snapshot and run only the
not-yet-committed suffix.

The rest of `soma_run` is already shaped for this. `pending` and `steps` are
already separate record fields. `resolve_args/2` already resolves a `from_step`
reference against the `outputs` map, so a pending step that points back into a
committed step works the moment `outputs` is seeded. `notify_session/1` already
sends `{run_completed, RunId, Outputs}` with the whole accumulated `outputs`
map. None of that has to change.

## Approach

Make the snapshot enter through `soma_run`'s start opts, and split `init/1` into
a normal start and a resume start.

- `steps` stays the full journaled list. The run keeps its identity; the
  reconstructed `steps` is what `reconstruct` read out of the original
  `run.started` journal.
- `pending` becomes its own opt: the not-yet-committed suffix. When the opt is
  absent it defaults to `steps`, so a normal start is unchanged.
- `outputs` becomes its own opt: the committed outputs keyed by step id. When
  absent it defaults to `#{}`, again unchanged for a normal start.

A start is a resume when the caller passes either `pending` or `outputs`. The
clean signal is "the snapshot is present". I'll key the branch on whether the
`pending` opt was supplied — a resumed run by definition carries a pending suffix
distinct from the full list, and v0.7.4 (the executor that builds these opts)
always sets both `pending` and `outputs` together from the reconstructed
snapshot. A normal start passes neither.

On a resume start, `init/1` emits `run.resumed` instead of `run.started`. The
`run.resumed` payload carries the run id (already on every event through `emit/1`)
and the first pending step id. It does **not** re-emit `run.started`: the original
`run.started` journal stays the single source of truth that `reconstruct` reads,
so reconstructing a resumed run still finds the full original step list, not a
truncated one. A normal start still emits `run.started` with the same payload it
emits today, byte for byte.

After `init/1`, both paths drop into the existing `{next_event, internal,
next_step}` loop with no further change. The resumed run walks its `pending`
suffix through the same `executing` / `waiting_tool` states — same monitored
`soma_tool_call` worker per step, same per-step timer, same kill-the-worker
teardown on timeout or cancel. The seeded `outputs` is already in `#data`, so
`resolve_args/2` finds a committed step's output when a pending step references it.

This is additive. The only behavioural fork is in `init/1`: pick the event type
and seed two fields that previously had fixed defaults.

The README run-event vocabulary line gets `run.resumed` added next to the other
run events, so the documented trail names the new event.

## Acceptance criteria → tests

All run-behaviour cases live in a new suite,
`apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`, started the same way as
`soma_run_happy_path_SUITE` (boot `soma_runtime`, start runs directly through
`soma_run:start_link/1` so resume opts can be passed, read the trail back through
`soma_event_store:by_run/2`). The README criterion is a source-file read.

### Criterion 1 — committed steps emit no step/tool start events
- Call chain: `soma_run:start_link/1` (with `pending` suffix + seeded `outputs`)
  → `init/1` → `executing` loop over the pending suffix only
- Test entry: `soma_run:start_link/1` (the real run entry; no session needed,
  the run is started directly so the resume opts can be passed)
- Test: `test_resume_emits_no_start_events_for_committed_steps` in
  `apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`

### Criterion 2 — each pending step runs in its own monitored worker
- Call chain: `soma_run:start_link/1` → `executing` → `start_tool_call/7` →
  `soma_tool_call:start/1` → monitored worker pid recorded on `tool.started`
- Test entry: `soma_run:start_link/1`
- Test: `test_each_pending_step_runs_in_own_worker` in
  `apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`

### Criterion 3 — a pending step's from_step into a committed step resolves
- Call chain: `soma_run:start_link/1` → `executing` → `resolve_args/2` reads the
  referenced step's output from the seeded `outputs`
- Test entry: `soma_run:start_link/1`
- Test: `test_pending_from_step_resolves_from_seeded_outputs` in
  `apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`

### Criterion 4 — resumed run completes and reports merged outputs to the session
- Call chain: `soma_run:start_link/1` (with `session_pid`) → pending steps run →
  `executing` reaches `pending = []` → `notify_session/1` sends
  `{run_completed, RunId, Outputs}` with seeded + newly-run outputs
- Test entry: `soma_run:start_link/1` with a test-process `session_pid`, which
  receives the `run_completed` message
- Test: `test_resumed_run_completes_with_merged_outputs` in
  `apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`

### Criterion 5 — a resume start emits run.resumed carrying run id + first pending step id
- Call chain: `soma_run:start_link/1` (resume opts) → `init/1` → `emit/1`
  `<<"run.resumed">>`
- Test entry: `soma_run:start_link/1`
- Test: `test_resume_emits_run_resumed_with_first_pending_step` in
  `apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`

### Criterion 6 — a resume start emits no run.started
- Call chain: `soma_run:start_link/1` (resume opts) → `init/1` takes the resume
  branch, never emitting `run.started`
- Test entry: `soma_run:start_link/1`
- Test: `test_resume_emits_no_run_started` in
  `apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`

### Criterion 7 — a normal start is unchanged (run.started, no run.resumed, full list)
- Call chain: `soma_run:start_link/1` (no `pending`, no `outputs`) → `init/1`
  takes the normal branch → emits `run.started` → runs the full list from step 0
- Test entry: `soma_run:start_link/1`
- Test: `test_normal_start_emits_run_started_and_no_run_resumed` in
  `apps/soma_runtime/test/soma_run_resume_seam_SUITE.erl`

### Criterion 8 — run.resumed is in the README run-event vocabulary
- Call chain: none (direct source-file read)
- Test entry: off the run chain — this is a documentation assertion, so the test
  reads `README.md` and checks the run-event list names `run.resumed`. Following
  the existing doc-assertion pattern in
  `apps/soma_runtime/test/soma_usage_docs_tests.erl`.
- Test: `test_readme_run_events_list_run_resumed` in
  `apps/soma_runtime/test/soma_usage_docs_tests.erl`

## Risks & trade-offs

- **The resume branch keys on the `pending` opt being present, not on a validated
  snapshot.** If a future caller passes `pending` without seeding the matching
  `outputs`, a pending step that references a committed step will fail on a missing
  prior step — the same `maps:get` failure a bad step list gives today. This slice
  is the mechanical seam, so it trusts its caller. The eligibility and
  classification that guard against a bad snapshot are v0.7.3, and the executor
  that builds the opts from a real `reconstruct` result is v0.7.4. Naming the
  contract here so the v0.7.3 plan layer owns the validation.

- **`run.resumed` is a second run-opening event type.** Any reader that assumed
  exactly one `run.started` opens a run now has to also recognize `run.resumed`.
  `reconstruct` is unaffected — it reads the original `run.started` journal, which
  a resume start deliberately does not overwrite — but a trace reader walking a
  resumed run's trail will see `run.resumed` where it expected `run.started`. That
  is the intended trade: keeping the journal stable is worth the second event
  type.
