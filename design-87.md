# v0.5.4: approved proposals execute (node A: intent → LLM → proposal → policy → run)

## Current state

The actor's success path for an LLM call ends at a verdict, not at action. In
`apps/soma_actor/src/soma_actor.erl`, the `{llm_result, ..., {ok, Output}}`
clause normalizes a proposal, emits `proposal.created`, then runs
`soma_policy:check/2`. On `allow` (around line 298) it sets the task status to
`approved`, emits `proposal.approved`, and replies the waiter with the proposal.
It starts no run. The comment at line 296 even spells this out: "honest that it
passed policy but has not run (executing is v0.5.4)".

So today an approved `run_steps` proposal is recorded as data and stops. The
chain intent → LLM → proposal → policy is closed, but the last hop — actually
running the approved steps — is missing. An approved `reply` / `reject` / `ask`
proposal sits at `approved` too, even though it has nothing left to do.

The execution machinery this slice needs already exists. `maybe_start_run/4`
(line 473) starts a `soma_run` the actor owns (`session_pid => self()`), monitors
the pid, tracks `run_id => task_id`, and sets the task `running`. The four
terminal-message clauses (`run_completed` line 189, `run_failed` line 206,
`run_timeout` line 222, `run_cancelled` line 238) and the `'DOWN'` backstop
(line 380) already turn a run's outcome into task state. The direct `steps`
envelope (the v0.4 path) drives all of this. This slice routes an approved
`run_steps` proposal down the same path.

## Approach

Change only the `allow` branch of the policy check. Split it by proposal kind.

For a `run_steps` proposal: after emitting `proposal.approved`, start a run.
Reuse the same owned-and-monitored path the direct `steps` envelope uses. Factor
the body of `maybe_start_run/4` into a helper that takes a steps list, a task id,
and a correlation id, then call it from both the envelope path and this proposal
path. The helper starts the run under `soma_run_sup`, monitors the pid, records
`run_id => task_id`, and sets the task `running`. Emit a `proposal.executed`
event carrying the task's `correlation_id` (and `llm_call_id`, matching the other
proposal events) at the point the run is started. Do not reply the waiter here —
leave the task at `running`. The existing terminal-message clauses already fire
when the run finishes: `run_completed` sets `completed`, stores the step outputs
as the task result, and replies the waiter. So an approved `run_steps` proposal
that is also being awaited gets its reply from the run's completion, not from the
gate.

One wiring detail: the `ask/3` path only parks a waiter when the envelope itself
carries `steps` (line 112). An `llm` envelope carries no `steps`, so an awaited
`llm` envelope is not parked there. That is fine for this slice — the waiter
handling for the llm/proposal path already lives in the `llm_result` clause via
`reply_waiter/3`, and the run's terminal clauses also call `reply_waiter/3`. The
issue's acceptance criteria drive through `send/2` plus polling, not `ask/3`, so
no waiter change is needed.

For a `reply` / `reject` / `ask` proposal (the toolless kinds): these have
nothing to run. Set the task status to `completed` with the normalized proposal
as the result, emit `proposal.approved` as before, and reply the waiter with the
proposal. This resolves the open question in the issue: an approved toolless
proposal reaches `completed`, not `approved`. The `approved` status becomes a
transient step toward `running` for `run_steps`, and is skipped entirely for the
toolless kinds (which go straight to `completed`).

Decide the kind with `maps:get(kind, Proposal)`. `run_steps` takes the run
branch; everything else takes the toolless branch. The policy gate already
allows toolless kinds without a tool check (v0.5.3), so reaching the `allow`
branch with a non-`run_steps` kind means it is a toolless kind.

What does not change: the `{reject, Reason}` branch (still records `rejected`,
emits `proposal.rejected`, starts no run), the direct `steps` envelope path, the
opaque-output path, the malformed-proposal path, and the bare no-steps envelope
behaviour. No new states, no new worker types, no new supervisor.

The new `proposal.executed` event marks the moment an approved `run_steps`
proposal hands off to a run. It is distinct from `run.started` (emitted by
`soma_run` itself): `proposal.executed` is the actor saying "I approved this and
am starting a run for it", `run.started` is the run saying "I have begun". Both
land under the same `correlation_id`, so `by_correlation/2` returns the full
chain.

## Acceptance criteria → tests

The actor-side execution proofs go in a new Common Test suite
`soma_proposal_exec_SUITE` in `apps/soma_actor/test/`, set up like
`soma_policy_SUITE`: boot `soma_runtime` so `soma_run_sup` and the event store
are alive, start an actor through `soma_actor_sup:start_actor/1` with a
`tool_policy`, and drive it through the real `soma_actor:send/2` with an `llm`
envelope carrying a `proposal` directive. Each proof reads outcomes back through
`get_task_status/2`, `get_task_result/2`, and `soma_event_store:by_correlation/2`.

The direct-steps and bare-envelope criteria are already covered by existing
`soma_actor_SUITE` cases; this slice re-pins them rather than re-proving them.

### Criterion 1 — approved run_steps reaches completed, result holds step outputs
- Call chain: `soma_actor:send/2` → `idle({call,From},{send,Envelope})` → `maybe_start_llm_call/4` → worker `{llm_result,...,{ok,Output}}` → `proposal_result/1` → `soma_policy:check/2` → run branch → `soma_run_sup:start_run` → run finishes → `idle(info,{run_completed,...})` → result stored
- Test entry: `soma_actor:send/2` (full chain, no layer bypassed)
- Test: `approved_run_steps_completes_with_step_outputs` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl`

### Criterion 2 — approved run_steps emits proposal.executed with correlation_id
- Call chain: `soma_actor:send/2` → llm_result success clause → policy `allow` → run branch emits `proposal.executed`
- Test entry: `soma_actor:send/2`, then read the event back through `by_correlation/2`
- Test: `approved_run_steps_emits_proposal_executed_with_correlation_id` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl`

### Criterion 3 — by_correlation returns the full chain under one correlation_id
- Call chain: `soma_actor:send/2` → full chain through to `run_completed`; every hop emits an event tagged with the task's `correlation_id`
- Test entry: `soma_actor:send/2`, then `soma_event_store:by_correlation/2`
- Test: `by_correlation_returns_full_approved_run_chain` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl` — asserts the trail names an `actor.*` event, an `llm.*` event, `proposal.created`, `proposal.approved`, `proposal.executed`, `run.started`, and `run.completed`

### Criterion 4 — the run executes in a soma_run pid that is not the actor pid
- Call chain: `soma_actor:send/2` → run branch → `soma_run_sup:start_run` (a separate process under `soma_run_sup`)
- Test entry: `soma_actor:send/2`, then read the run pid (from the `run.started`/`run.completed` event's source or by asserting the run ran under `soma_run_sup`) and compare to the actor pid
- Test: `approved_run_steps_runs_in_distinct_pid` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl`

### Criterion 5 — rejected proposal starts no run, status rejected
- Call chain: `soma_actor:send/2` → llm_result success clause → policy `{reject, Reason}` branch (unchanged)
- Test entry: `soma_actor:send/2`, then `by_correlation/2` and `get_task_status/2`
- Test: `rejected_proposal_starts_no_run_status_rejected` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl` — asserts the trail carries `proposal.rejected` and no `run.started`, and the status reads `rejected`

### Criterion 6 — approved reply proposal completes with the proposal as result, no run
- Call chain: `soma_actor:send/2` → llm_result success clause → policy `allow` → toolless branch → task `completed`
- Test entry: `soma_actor:send/2`, then `get_task_status/2`, `get_task_result/2`, and `by_correlation/2`
- Test: `approved_reply_proposal_completes_no_run` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl` — asserts status `completed`, result is the normalized proposal, and the trail shows no `run.started`

### Criterion 7 — failed run from approved run_steps marks task failed, actor alive
- Call chain: `soma_actor:send/2` → run branch → `soma_run_sup:start_run` → a step's tool errors/crashes → run reports `{run_failed, ...}` → `idle(info,{run_failed,...})` → task `failed`
- Test entry: `soma_actor:send/2` with a proposal whose allowed steps include the `fail` tool; then `get_task_status/2` and `is_process_alive/1`
- Test: `approved_run_steps_failing_tool_marks_task_failed_actor_alive` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl`

### Criterion 8 — actor takes a second llm envelope after a failed run
- Call chain: same failing chain as Criterion 7, then a second `soma_actor:send/2` driven to `completed`
- Test entry: `soma_actor:send/2` twice on the same actor pid
- Test: `actor_survives_failed_run_takes_next_llm_envelope` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl`

### Criterion 9 — direct steps envelope still completes, emits no proposal.* event
- Call chain: `soma_actor:send/2` with a `steps` envelope → `maybe_start_run/4` → `soma_run_sup:start_run` → `run_completed` (the v0.4 path, untouched)
- Test entry: `soma_actor:send/2` with a steps envelope; assert status `completed` and that `by_correlation/2` carries no `proposal.*`-typed event
- Test: `direct_steps_completes_no_proposal_event` in `apps/soma_actor/test/soma_proposal_exec_SUITE.erl` (the v0.4 happy path itself stays pinned by `soma_actor_SUITE` · `task_status_completed_after_run`; this case adds the "no proposal event" half this slice must not break)

### Criterion 10 — bare no-steps no-llm envelope accepted, no run
- Call chain: `soma_actor:send/2` → `idle({call,From},{send,Envelope})` → `maybe_start_run/4` (no-op) → `maybe_start_llm_call/4` (no-op)
- Test entry: existing `soma_actor:send/2` no-steps proof
- Test: `no_steps_accepts_and_starts_no_run` in `apps/soma_actor/test/soma_actor_SUITE.erl` (existing; re-pinned by this slice's contract section)

### Criterion 11 — v0.5.4 contract section maps each proof to its suite and case
- Call chain: none (direct source-file read)
- Test entry: the contract-pin test reads `docs/contracts/v0.5-test-contract.md`
- Test: covered by the pin in Criterion 12 below; the section itself is the artifact added to `docs/contracts/v0.5-test-contract.md`

### Criterion 12 — contract-pin test reads the v0.5.4 section and asserts every suite and case
- Call chain: none (direct source-file read)
- Test entry: the pin test opens the contract file and matches each v0.5.4 suite name and case name as substrings
- Test: `pins_v0_5_test_contract_maps_each_proof` in `apps/soma_actor/test/soma_llm_call_SUITE.erl` (extended to also require `soma_proposal_exec_SUITE` and every v0.5.4 case name)

### Criterion 13 — rebar3 eunit && rebar3 ct is green
- Call chain: none (build gate)
- Test entry: the merge gate runs `rebar3 eunit && rebar3 ct`
- Test: the full suite set above plus the existing suites, all green

## Risks & trade-offs

The toolless kinds now reach `completed` instead of staying at `approved`. This
is a behaviour change to the v0.5.3 approved path. The issue's open question
calls it out and resolves it this way, so it is intended, but any test or caller
that asserted a toolless proposal ends at `approved` would need updating. The
v0.5.3 actor-side cases use `run_steps` proposals for the `approved`-status
proofs (`soma_policy_SUITE` · `allowed_proposal_status_reads_approved`), and
those now reach `running` then `completed` rather than resting at `approved`. So
that v0.5.3 case has to change with this slice: it can no longer assert the task
rests at `approved`. The clean reading is to move the "rests at approved"
expectation out — an approved `run_steps` proposal is no longer terminal at
`approved`. This slice should update `soma_policy_SUITE` accordingly rather than
leave a contradicting assertion.

The reused run-start helper means a bug in the shared path now affects both the
direct `steps` envelope and the approved `run_steps` proposal. That is the point
— one path, one set of failure semantics — but it does mean the proposal path
inherits whatever the envelope path does, including the `'DOWN'` backstop and the
monitor bookkeeping. The factoring must keep the envelope path's behaviour
byte-for-byte; Criterion 9 guards that the direct path still completes.

`proposal.executed` is a new event type. It is additive — nothing consumes it
except `by_correlation/2` queries — so it carries no compatibility risk, but it
does need to be listed wherever the event-type set is documented if such a list
is pinned.
