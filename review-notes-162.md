### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The resume branch keys on `maps:is_key(pending, Opts)` alone. A caller passing `pending` without seeding the matching `outputs` produces a `badkey` crash in `resolve_args/2` the moment a pending step references a committed step. The design names this and parks the snapshot validation in v0.7.3. Fine as a seam, but the next slice owns it — confirm v0.7.3 actually guards it.
- A start that passes `outputs` but omits `pending` stays a normal start: it emits `run.started` and re-runs from step 0 while carrying seeded outputs. Nothing in this slice produces that combination, and the design says the executor always sets both together. Worth a one-line contract note so a future caller doesn't half-seed and get silent re-execution.

## Nits
- `run.resumed` carries no `step_id`; the store backfills it to `undefined`. Same as `run.started` today, so it's consistent — not a defect, just noting the first pending step lives only in `payload.first_pending_step`.

## Functional evidence
- Criterion 1 — pass: `test_resume_emits_no_start_events_for_committed_steps` asserts no `step.started`/`tool.started` names s1 (the committed, seeded step), while s2's start events are present. Green in `soma_run_resume_seam_SUITE` (7/7).
- Criterion 2 — pass: `test_each_pending_step_runs_in_own_worker` — s1 has zero `tool.started`, the two pending steps yield exactly 2 distinct `tool_call_pid`s, all real pids, none equal to the run pid.
- Criterion 3 — pass: `test_pending_from_step_resolves_from_seeded_outputs` — s2 is a bare `#{from_step => s1}` echo; run reaches `run.completed`, no `run.failed`, and s2's recorded output equals the seeded `#{value => <<"seeded">>}`. `resolve_args/2` reads s1 from seeded `outputs`.
- Criterion 4 — pass: `test_resumed_run_completes_with_merged_outputs` — test process is `session_pid`, receives `{run_completed, RunId, Out}`; `Out` has s1 (seeded), s2, s3 (newly run), `map_size = 3`.
- Criterion 5 — pass: `test_resume_emits_run_resumed_with_first_pending_step` — exactly one `run.resumed` event, `run_id` matches, `payload.first_pending_step = s2`. Code: `soma_run.erl:62-64` emits it with `first_pending_step(Data#data.pending)`.
- Criterion 6 — pass: `test_resume_emits_no_run_started` — trail read back through `by_run/2` carries no `run.started`. Code: `init/1` resume branch at `soma_run.erl:60-64` never emits `run.started`.
- Criterion 7 — pass: `test_normal_start_emits_run_started_and_no_run_resumed` — no `pending`/`outputs` opts; trail has `run.started`, no `run.resumed`, and both s1 and s2 have `step.started`.
- Criterion 8 — pass: `README.md:202` run-event vocabulary now reads "...`run.cancelled`), and a resumed run emits `run.resumed`." Asserted by `test_readme_run_events_list_run_resumed` in `soma_usage_docs_tests` (eunit 3/3 green).
