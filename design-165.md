# v0.7.3: resume plan — eligibility + fail-safe in-flight classification

## Current state

Two halves of resume already exist, with nothing connecting them.

`soma_run_resume:reconstruct/2` reads the durable trail (`soma_event_store:by_run/2`) and rebuilds a snapshot: `#{steps, run_options, outputs, next_step, terminal_status}`. `next_step` is the first journaled step with no committed `step.succeeded` output, returned as the whole step map, or `undefined` when every journaled step is committed. `terminal_status` is `completed`/`failed`/`timeout`/`cancelled` when a terminal run event is on the trail, else `undefined`. It rejects a trail with no usable journal (`{error, no_run_started_journal}`) and a trail that committed a step the journal never declared (`{error, {unknown_committed_step, StepId}}`). It is read-only.

`soma_run` (after #162) can start mid-list: pass `pending` (the not-yet-committed suffix) plus seeded `outputs`, and it opens with `run.resumed` instead of `run.started` and walks only the pending suffix. The `from_step` resolver reads committed values out of the seeded `outputs`.

What is missing is the decision between them. `reconstruct` tells you where a run stopped, but not whether restarting it is safe. The dangerous case is a run that crashed while a `state` step was mid-execution: blindly re-running it could repeat an irreversible write. Nobody computes that today. `reconstruct` does not even look at the registry, so it cannot know a step's `effect`/`idempotent` — those live only in the descriptor, never on the trail.

## Approach

Add a read-only plan module, `soma_run_resume_plan`, in `apps/soma_runtime/src/`. One entry point: `plan(StorePid, RunId)`. It calls `reconstruct/2`, then classifies the snapshot against the trail and the registry, and returns a verdict. It starts no run and appends no events. It does not import `soma_actor`.

### Verdict shape

Five verdicts. I am using tagged tuples, with the `resume` payload as a map so its four fields are named.

- `{resume, #{steps, pending, outputs, run_options}}` — safe to restart.
- `{unsafe, StepId}` — an in-flight non-idempotent `state` step; do not restart.
- `{terminal, Status}` — the run already finished; `Status` is `completed`/`failed`/`timeout`/`cancelled`.
- `nothing_to_do` — every journaled step is committed and there is no terminal event.
- `{error, Reason}` — passed through from `reconstruct` unchanged.

The `resume` payload carries exactly what the v0.7.2 seam consumes, so the v0.7.4 executor can hand it to `soma_run:start_link/1` without re-deriving anything. `steps` is the full journaled list. `pending` is the suffix from `next_step` to the end. `outputs` and `run_options` are passed through from the snapshot. The unsafe case names the offending `StepId` so the executor can land a `failed {resume_unsafe, StepId}` later.

### Decision order

The order matters because more than one condition can be true at once. A terminal trail can still have an uncommitted `next_step` (a run that failed mid-step leaves the step uncommitted and writes `run.failed`). Terminal wins.

1. `reconstruct` returned `{error, _}` → return it unchanged.
2. `terminal_status` is not `undefined` → `{terminal, Status}`. This is checked before `next_step`, so a terminal trail never returns `resume`.
3. `next_step` is `undefined` → `nothing_to_do`.
4. `next_step` is a step. Look for a `tool.started` event whose `step_id` equals that step's id.
   - No such event (crash landed between steps) → safe → `resume`.
   - There is one (crash hit mid-step). Resolve the step's tool through `soma_tool_registry:resolve_descriptor/1` and read the risk:
     - `effect` is `reader` or `identity`, or `idempotent => true` → safe → `resume`.
     - `effect => state` and `idempotent => false` → `{unsafe, StepId}`.

### Reading the in-flight signal

The plan re-reads the trail with `soma_event_store:by_run/2` to find `tool.started`. `reconstruct` does not surface that event, and threading a second return value through it would widen its contract for one caller. A second read of the same trail is cheaper than the coupling, and the plan is already read-only, so a duplicate read changes nothing observable.

### Reading the risk

Risk comes from the live registry, the same `soma_tool_registry:resolve_descriptor/1` the runtime resolves tools through. The descriptor carries `effect` and `idempotent` directly (every built-in `describe/0` sets them; `soma_tool_manifest:normalize/1` keeps them on the descriptor). The plan only reads two fields off the resolved descriptor. It never spawns a worker.

If the step names a tool the registry no longer knows (`{error, not_found}`), the safe rule cannot be evaluated. Re-running an unknown tool would fail at the registry anyway, so the conservative call is to treat an unresolvable in-flight step as `{unsafe, StepId}` — the plan refuses to bless a restart it cannot prove safe. This is a corner the acceptance criteria do not name; the design picks the fail-safe side and the risks section flags it.

## Acceptance criteria → tests

All tests go in a new suite `soma_run_resume_plan_SUITE` in `apps/soma_runtime/test/`. Each seeds a trail by appending events to the store directly (the journal-suite pattern), or runs a real session, then calls `soma_run_resume_plan:plan/2`. The plan reads the registry, so the suite runs under a started `soma_runtime` application, which has the registry seeded with the built-ins (`echo` identity, `file_read` reader, `file_write` state/non-idempotent).

### Criterion 1 — interrupted between steps returns resume with the pending suffix
- Call chain: `soma_run_resume_plan:plan/2` → `soma_run_resume:reconstruct/2` → `soma_event_store:by_run/2`, then the plan's own second `by_run/2` read for `tool.started`
- Test entry: `soma_run_resume_plan:plan/2` (the module's only entry point; the test reads the verdict it returns)
- Test: `test_between_steps_resumes_with_pending_suffix_outputs_and_options` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Seed a two-step journal `[s1, s2]`, commit `s1` via `step.succeeded`, no `tool.started` for `s2`. Assert the verdict is `{resume, P}` where `pending` is `[s2]`, `steps` is `[s1, s2]`, `outputs` is `#{s1 => ...}`, and `run_options` matches the journal.

### Criterion 2 — interrupted during a safe step returns resume
- Call chain: `soma_run_resume_plan:plan/2` → `reconstruct/2` → `by_run/2`, then the plan's `by_run/2` for `tool.started` and `soma_tool_registry:resolve_descriptor/1` for the risk
- Test entry: `soma_run_resume_plan:plan/2`
- Test: `test_in_flight_safe_step_resumes` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Seed a journal whose `next_step` uses `file_read` (`reader`, idempotent), append a `tool.started` for that step id. Assert the verdict is `{resume, _}`.

### Criterion 3 — interrupted during an unsafe step returns {unsafe, StepId} and never resume
- Call chain: same as criterion 2
- Test entry: `soma_run_resume_plan:plan/2`
- Test: `test_in_flight_unsafe_state_step_is_unsafe` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Seed a journal whose `next_step` uses `file_write` (`state`, `idempotent => false`), append a `tool.started` for that step id. Assert the verdict is `{unsafe, StepId}` with the offending step id, and assert it is not an `{resume, _}` tuple.

### Criterion 4 — terminal trail returns {terminal, Status} even with an uncommitted next_step
- Call chain: `soma_run_resume_plan:plan/2` → `reconstruct/2` → `by_run/2`
- Test entry: `soma_run_resume_plan:plan/2`
- Test: `test_terminal_trail_returns_terminal_status_over_next_step` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Seed a journal `[s1, s2]`, leave `s2` uncommitted, append a `run.failed`. Assert the verdict is `{terminal, failed}` and not `{resume, _}`. A second assertion covers a `run.completed` trail mapping to `{terminal, completed}`.

### Criterion 5 — all committed, no terminal event returns nothing_to_do
- Call chain: `soma_run_resume_plan:plan/2` → `reconstruct/2` → `by_run/2`
- Test entry: `soma_run_resume_plan:plan/2`
- Test: `test_all_committed_no_terminal_is_nothing_to_do` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Seed a single-step journal and commit that step, no terminal event. `reconstruct` returns `next_step => undefined`. Assert the verdict is `nothing_to_do`.

### Criterion 6 — propagates reconstruct's errors unchanged
- Call chain: `soma_run_resume_plan:plan/2` → `reconstruct/2` → `by_run/2`
- Test entry: `soma_run_resume_plan:plan/2`
- Test: `test_propagates_reconstruct_errors` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Two cases in one test. A trail with no usable journal returns `{error, no_run_started_journal}`. A trail that commits a step the journal never declared returns `{error, {unknown_committed_step, StepId}}`. Both come straight back from `reconstruct`.

### Criterion 7 — plan appends no events and starts no run child
- Call chain: `soma_run_resume_plan:plan/2` → `reconstruct/2` → `by_run/2`
- Test entry: `soma_run_resume_plan:plan/2`
- Test: `test_plan_is_read_only` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Run a real session to a committed trail. Snapshot `soma_event_store:all/1` and `supervisor:count_children(soma_run_sup)` before and after the plan call. Assert the event store is byte-for-byte equal and the child count is unchanged. This mirrors the two read-only proofs in `soma_run_resume_journal_SUITE`.

### Criterion 8 — resume payload carries steps, pending, outputs, run_options for the seam
- Call chain: `soma_run_resume_plan:plan/2` → `reconstruct/2` → `by_run/2`
- Test entry: `soma_run_resume_plan:plan/2`
- Test: `test_resume_payload_has_four_seam_fields` in `apps/soma_runtime/test/soma_run_resume_plan_SUITE.erl`

Take a between-steps `{resume, P}` verdict and assert `P` has exactly the keys `steps`, `pending`, `outputs`, `run_options`. Then feed `P` straight into `soma_run:start_link/1` (mapping the four payload fields plus `run_id`/`event_store` onto the resume opts) and assert the resumed run reaches `run.completed`, proving the seam consumes the payload without re-deriving anything.

## Risks & trade-offs

- **The plan reads the trail twice** — once inside `reconstruct`, once for `tool.started`. That is a deliberate trade: it keeps `reconstruct`'s return contract narrow rather than widening it for one caller. The cost is a second `by_run/2` on the same run, which is bounded and read-only.
- **An unresolvable in-flight tool is treated as unsafe.** If the registry no longer knows the tool of an in-flight step, the plan returns `{unsafe, StepId}` rather than `resume`. The acceptance criteria do not name this case. Treating it as resumable would bless a restart that fails at the registry anyway, so the fail-safe side is the right default, but it does mean a tool that was unregistered for an unrelated reason blocks an otherwise-safe resume until it is re-registered.
- **Risk lives in the live registry, not the trail.** The plan reads `effect`/`idempotent` from the descriptor at plan time, so a tool whose risk profile changed between the original run and the resume is judged by today's profile, not the one in force when it ran. For the fail-safe rule this is the safer direction (a tool that became `state` is now correctly refused), and the trail does not carry these fields anyway, so there is no alternative source.
- **The in-flight signal is `tool.started` alone.** A step that emitted `tool.started` and then `tool.succeeded`/`tool.failed` would already be committed (or terminal), so `next_step` would have moved past it or `terminal_status` would be set. The signal is only consulted for the uncommitted `next_step`, so a stale `tool.started` from an earlier committed step cannot misfire.
