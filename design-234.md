# [cc] soma.delegate AS.5a: per-task coordinator and disposable round workers

## Current state

The runtime already has the process boundaries that delegated work must keep.
`soma_run_sup` starts a temporary `soma_run` child for one canonical flat step
list. The run owns step order, tool-call monitors, step timers, cancellation,
and external-process teardown. Every tool invocation starts in a linked and
monitored `soma_tool_call` process.

`soma_llm_call` is also disposable, but its current `start/1` API returns only
the worker pid. `soma_actor` adds its own monitor and timer after that call. The
actor owns the LLM worker and any later run directly.

Optional multi-round exploration currently lives inside the long-lived
`soma_actor`. Its task map contains the original envelope, transcript, round
number, budgets, active LLM fields, active run fields, and the terminal result.
The actor clears finished child fields between exploration rounds, but all
tasks still share one actor process and one actor state record. That ownership
shape can inherit unrelated actor state and cannot give one delegated request
an isolated lifetime.

`soma_service` provides a useful ingress pattern for already-decided
`soma.run` work. Its registered `gen_server` serializes request-id
deduplication, routes status and cancellation, monitors runs, removes terminal
run children, and stores bounded public task projections. It must remain the
no-LLM runtime service. Delegated coordination must not be added to that
process or to its request contract.

`soma_actor_sup` has no delegate ingress, coordinator supervisor, round-worker
supervisor, or task-scoped lease owner. There is no process that can release a
delegated task's leases after its coordinator is killed. There is also no
round-result protocol that rejects stale or mismatched worker messages.

The event store accepts arbitrary maps and adds its mandatory event fields. It
does not enforce a producer-specific byte ceiling or remove unsafe nested
terms. Existing exploration events use a small allowlist, and `soma_trace`
already renders their top-level `round` field. A delegate event boundary still
needs its own allowlist, scrubber, and measured cap.

The current gate already pins the contracts that this issue must preserve.
`soma_service_SUITE:test_single_tool_invocation_runs_without_llm_worker`
proves the deterministic `soma.run` path.
`soma_cli_server_SUITE:test_run_lisp_echo_returns_completed_result` proves the
local CLI result shape. `soma_actor_SUITE:task_result_holds_outputs_after_run`
proves the actor result shape.

## Approach

Add the delegate substrate inside `apps/soma_actor`. It belongs above
`soma_runtime` and may import runtime modules. No runtime module may import a
delegate module.

Extend `soma_actor_sup` with four children before the existing dynamic actor
supervisor:

- `soma_delegate_coordinator_sup` is a dynamic supervisor for
  `soma_delegate_coordinator` children. Its child specification uses
  `restart => temporary`.
- `soma_delegate_round_sup` is a dynamic supervisor for
  `soma_delegate_round_worker` children. Its child specification also uses
  `restart => temporary`.
- `soma_delegate_lease_sup` is a dynamic supervisor for one
  `soma_delegate_lease_guard` per active delegated task. Lease guards are
  temporary children.
- `soma_delegate` is a permanent, locally registered `gen_server` and the
  production Erlang ingress.

The child order makes every dynamic supervisor available before the ingress
accepts work. A coordinator or round-worker crash cannot restart that child
and does not count as an ingress failure.

### Delegate ingress

Expose `soma_delegate:submit/1`, `soma_delegate:status/1`, and
`soma_delegate:cancel/1`. This issue does not add a Lisp form, socket operation,
or CLI command.

`submit/1` accepts an already-normalized Erlang task specification. The
ownership substrate needs bounded binary `request_id` and optional
`correlation_id` fields, a bounded objective, an optional output contract,
initial checkpoint data, budgets, and task-scoped lease requests. #233 owns
the final request normalizer and public meaning of those fields.

The ingress performs only structural AS.5a validation. It rejects an invalid
or over-limit identity and rejects task data that cannot fit the coordinator's
fixed bounds. It does not interpret an objective, output contract, checkpoint,
or action proposal.

The ingress gen_server is the serialized request-id authority. On the first
request id it mints one task id, resolves the correlation id, builds one
immutable accepted handle, and starts one coordinator. It stores the route
before telling the coordinator to begin. A later submit with that request id
returns the same accepted handle. It never starts a replacement coordinator,
including after the original task is terminal or its coordinator crashed.

The ingress state may retain only these task-scoped values:

- request id to task id routing.
- the immutable accepted handle.
- an active coordinator pid and monitor reference.
- cancellation callers waiting for terminal cleanup.
- one terminal projection of at most 512 deterministic external-term bytes.

It must not retain the submitted task specification, objective, output
contract, checkpoints, budget counters, mutation data, unknown outcomes,
lease requests, handles, round snapshots, child pids below the coordinator, or
the full terminal result.

An active `status/1` call is forwarded to the coordinator. A terminal status
is read from the ingress projection. `cancel/1` sends one cancellation request
to the active coordinator and replies only after the coordinator reports its
cleaned terminal projection. Repeated cancellation returns the stored
cancelled projection. A coordinator monitor `DOWN` becomes bounded
`coordinator_crashed` task data and leaves the registered ingress serving.

Start coordinators in an `awaiting_start` state. `soma_delegate` installs the
route and monitor before it sends the matching begin message. This removes the
start-versus-monitor race for a coordinator that fails immediately.

The AS.5a lifecycle vocabulary is `accepted`, `running`, `succeeded`,
`failed`, `timeout`, `cancelled`, and `in_doubt`. #233 may wrap these states in
its final delegate result, but it must not weaken their terminal meaning.

### Per-task coordinator

Implement `soma_delegate_coordinator` as a `gen_statem`. One process owns one
delegated task. Its state owns all of the following until the cleanup
transition:

- request, task, and correlation ids.
- objective and output contract.
- current context checkpoint and bounded recent round data.
- configured budgets and committed usage.
- committed mutation entries and unknown-outcome entries.
- the lease guard identity and the opaque handle set.
- the next round id and active-round record.
- the complete bounded terminal result while cleanup is in progress.

The active-round record contains the integer round id, a bounded binary worker
identity, worker pid, worker monitor reference, result capability, round timer,
and the unsafe-action dispatch marker. The coordinator owns those fields and
no LLM, run, tool-worker, port, or external OS pid.

Use monotonically increasing positive integers for round ids within one task.
Start at one. A later round is a new decision cycle, not a retry of the prior
round.

The coordinator builds one immutable round snapshot before each worker start.
Its deterministic external-term size must not exceed 65,536 bytes. The
snapshot contains only the bounded objective and output contract, projected
checkpoint, remaining budgets, committed usage, exact mutation and unknown
outcome data, task and correlation ids, and the same opaque lease handles
acquired at task start. It contains no product conversation or history,
product user or session identity, authentication data, provider secret, raw
lease, lease-guard pid, resource-manager pid, worker pid, monitor reference,
port, or prior snapshot.

Erlang terms are immutable, so the worker receives a copied value. Never give
the worker a function that reads live coordinator state.

Issue #233 owns the model decision protocol, projector, action proposal, and
final delegate-result schema. To test AS.5a before that issue, allow a direct
Erlang `round_sequence` key in the submitted test fixture. The ingress passes it once
in coordinator start options and never retains it. It is analogous to the
existing fixed provider response sequence. Each entry receives the immutable
snapshot and returns one already-prepared round work map with LLM options,
optional canonical action steps, and a continue-or-terminal fixture decision.
This seam is not loaded from config, Lisp, or a socket. It is never written to
events. It defines no public proposal syntax.

Start each round worker in `awaiting_start`. The coordinator obtains its pid,
installs the monitor, creates a fresh bounded worker identity and result
capability, arms the overall round timer, stores the active-round record, and
only then sends begin. A worker that crashes at its first instruction is still
owned by the correct monitor.

### Disposable round worker

Implement `soma_delegate_round_worker` as a temporary `gen_statem`. It owns one
decision/action cycle and exits after reporting one bounded result. It receives
process-control metadata, the immutable snapshot, opaque handles, and one
prepared work map. It receives no coordinator state table or task lease data.
The process-control metadata is not task context. The round worker monitors its
coordinator and cleans its own active child before exit if that owner dies.

Add an additive `soma_llm_call:start_owned/1` API. Keep the existing `start/1`
contract unchanged. `start_owned/1` uses an owner-link handshake and
`spawn_monitor`, matching `soma_tool_call:start/1`. It returns the worker pid
and monitor reference only after the LLM child has linked to the calling round
worker. The round worker traps exits, owns the LLM monitor and call timer, and
kills and awaits that child on timeout or cancellation.

After a successful LLM result, validate that prepared action steps are a flat
list of canonical step maps. Do not parse a proposal or add a workflow
language. Resolve descriptors only to classify repeat safety. Prepared actions
still enter `soma_run_sup:start_run/1` unchanged. Reuse
`soma_run_resume_safety:descriptor_safe/1` so the delegate does not create a
second repeat-safety rule.

Start an action run with `session_pid => self()`, the delegated task and
correlation ids, the runtime event store, the canonical steps, and
`auto_resume => false`. Monitor and link the run from the round worker. The
link makes an abnormal round-worker death reach `soma_run`. The run's existing
terminate path then stops a live `soma_tool_call` and external process. The
round worker owns its run monitor, action timer, cancel message, and terminal
child removal through `supervisor:terminate_child/2`.

On action cancellation, send `cancel` to the run and wait for its terminal
message. Remove the terminal run child before reporting the round result. If a
tool worker is still leaving after a run crash, use the current event trail to
monitor that worker until it is dead, following the cleanup pattern already in
`soma_service`. The public cancel call cannot complete while a round worker,
LLM call, run, tool worker, or recorded CLI OS process remains alive.

The round worker may place opaque handles in canonical step arguments. It may
not receive or resolve raw leases. A handle-aware tool can pass the handle to
the product resource boundary during its ordinary `soma_tool_call`
invocation. AS.5a test tools record that only the opaque handle crossed this
path.

### Round protocol and commit order

Use one internal result message shape:

```text
{delegate_round_result, TaskId, RoundId, WorkerPid, WorkerIdentity,
 ResultCapability, BoundedResult}
```

The result payload has a maximum deterministic external-term size of 16,384
bytes. It contains bounded status, phase, usage, checkpoint, mutation,
unknown-outcome, and terminal-result deltas. It does not contain raw child
state or provider configuration.

The coordinator accepts the message only when all identity fields match its
current active-round record. It validates the payload before changing state.
For one valid result it applies this exact order:

1. validate the result and its size.
2. commit checkpoint, usage, mutation, unknown-outcome, and terminal-result
   deltas exactly once.
3. cancel the round timer.
4. demonitor and remove the finished temporary worker.
5. clear the active-round record.
6. start the next distinct worker or enter terminal cleanup.

Messages for a past round, a completed round, another task, another round,
another worker, or another result capability are no-ops. They must not update
status, ids, checkpoint, budget, usage, ledgers, leases, timers, active-round
data, or terminal data.

The worker sends an unsafe-action dispatch marker before it starts a run that
contains a descriptor not safe to repeat. Erlang signal ordering ensures that
the coordinator receives this marker before a later monitor `DOWN` from the
same worker. A worker loss before that marker becomes bounded pre-stateful
round failure data. The fixed-round seam may choose a later distinct round,
which proves the coordinator remains live without silently retrying the failed
round.

A worker loss after that marker is conservative. The coordinator records the
known invocation identity once, appends one unknown outcome, sets task status
to `in_doubt`, and enters cleanup. It starts no replacement worker and never
replays the run. The runtime event trail proves whether one tool invocation
crossed `tool.started`.

The coordinator owns one overall round timeout. When it fires, the coordinator
sends a timeout cancellation to the active worker and waits for worker-owned
child teardown. A short forced-stop deadline is a backstop for a worker that
does not honor cancellation. Pre-stateful forced stops become bounded timeout
data. A forced stop after unsafe dispatch becomes `in_doubt`.

### Task-scoped leases

Add `soma_delegate_lease_guard` and a small
`soma_delegate_lease_adapter` behavior. A configured adapter acquires one
named task-scoped lease as `{OpaqueHandle, RawLease}` and releases the raw
lease. The guard stores raw leases. The coordinator stores only the stable
name-to-handle map.

Start one guard per task before the first round. The guard acquires each
configured lease once, monitors its coordinator, and returns the complete
handle map. A partial acquisition failure releases every earlier acquisition
once and fails the task before a round starts.

Normal coordinator cleanup calls the guard's idempotent `release_all` before a
terminal projection becomes public. The guard removes each raw lease from its
owned table before calling the adapter release callback. A repeated cleanup
message cannot call the adapter again. If the coordinator crashes, the guard's
owner monitor performs the same release and exits. This is the crash backstop,
not a second semantic lease owner.

Every round snapshot receives the original handle map. No round reacquires a
lease. Concurrent guards keep raw lease tables disjoint by task.

### Terminal cleanup

All expected terminal outcomes enter one coordinator state named `cleaning`.
The entry is guarded by a `cleanup_started` flag. Success, bounded failure,
timeout, cancellation, rejection from the fixed seam, and `in_doubt` cannot
append a second terminal record.

The cleaning state stops an active round through its owner protocol, cancels
and flushes the round timer, removes the temporary worker, releases the lease
guard, builds the bounded terminal projection, emits one terminal delegate
event, and notifies the ingress. The coordinator then exits normally. Its heap
releases the objective, checkpoints, round inputs, budget state, ledgers,
handles, and full terminal result.

`terminate/3` asks the lease guard to release as a best-effort backstop for
catchable coordinator exits. The lease guard's monitor covers an untrappable
kill. The ingress monitor covers the projection when no normal terminal
message arrives.

A new request always starts a new coordinator with fresh task state. It can
share no map, process dictionary entry, lease guard, worker, or callback state
with a terminal task.

### Delegate events

Add `soma_delegate_event` as the only producer for event types beginning with
`delegate.`. It constructs complete event maps, including all event-store
mandatory keys, before measuring them. `max_bytes/0` returns 4096. The helper
uses deterministic external-term encoding and falls back to a fixed bounded
outcome summary if an allowed dynamic field would exceed the cap.

The initial event set is `delegate.task.accepted`,
`delegate.task.running`, `delegate.round.started`,
`delegate.round.completed`, `delegate.task.cancel_requested`,
`delegate.task.cleanup`, and `delegate.task.terminal`. Normal terminal work
emits one cleanup event followed by one terminal event. No event carries the
full result.

Every delegate event carries `task_id`, `correlation_id`, and a top-level
`round`. Task-level events use round zero. Round events use the positive round
id. The existing trace formatter will display the round without a change to
runtime execution.

Allow only bounded lifecycle fields such as event type, stable ids, status,
phase, reason class, usage counts, mutation count, unknown-outcome count, and
truncation metadata. Do not merge task maps or round results into events.

Recursively reject or redact pids, monitor references, ports, functions,
secrets, raw leases, product user or session data, product conversation data,
provider configuration, executable internals, round snapshots, and arbitrary
tool output. Core run and tool events keep their existing contract. The new
cap and scrub rule apply to `delegate.*` lifecycle events.

### Tests and compatibility

Put the process tests in
`apps/soma_actor/test/soma_delegate_SUITE.erl`. Use fixed LLM directives and
fixed provider responses only. Generate any CLI cancellation stub in the test
temporary directory. Add test-only lease adapters and handle-aware tools under
`apps/soma_actor/test/`. No test opens a provider or non-local network
connection.

Add `docs/contracts/AS.5a-test-contract.md` during development. It documents
the 4096-byte delegate event cap and maps each issue criterion to exactly one
new hermetic case. Its compatibility section also pins the three existing
representative proofs named in Current state. The full merge gate remains
`rebar3 eunit && rebar3 ct`.

## Acceptance criteria → tests

### Criterion 1 — one request identity owns one coordinator

- Call chain: `soma_delegate:submit/1` → registered ingress dedupe →
  `soma_delegate_coordinator_sup:start_coordinator/1` → coordinator
  `awaiting_start` → monitored begin message.
- Test entry: `soma_delegate:submit/1` twice with one request id while the first
  round is blocked. The case compares the accepted handles, counts one live
  coordinator, confirms no replacement pid appears, and reads all three ids
  from that coordinator until cleanup. No ownership layer is bypassed.
- Code boundary: ingress routing in
  `apps/soma_actor/src/soma_delegate.erl`, dynamic child startup in
  `soma_delegate_coordinator_sup.erl`, and identity retention in
  `soma_delegate_coordinator.erl`.
- Responsibility owner: `soma_delegate` owns atomic request routing.
  `soma_delegate_coordinator` owns the request, task, and correlation ids for
  the task lifetime.
- Test: `test_request_identity_reuses_one_live_coordinator` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 2 — coordinator state does not leak into ingress state

- Call chain: delegate submit → coordinator initialization → lease
  acquisition → first round commit → later blocked round → terminal
  cleanup → bounded ingress projection.
- Test entry: `soma_delegate:submit/1`. The case uses `sys:get_state/1` only to
  inspect both OTP owners while production work is blocked at deterministic
  test barriers.
- Code boundary: state maps in `apps/soma_actor/src/soma_delegate.erl` and
  `apps/soma_actor/src/soma_delegate_coordinator.erl`, plus terminal projection
  shaping in `soma_delegate.erl`.
- Responsibility owner: the coordinator owns every task-local value named by
  the issue. The ingress owns routes and public projections only.
- Test: `test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections`
  in `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 3 — status and cancellation route by task id

- Call chain: `soma_delegate:status/1` or `cancel/1` → task route lookup →
  active coordinator status or cancel protocol → worker-owned teardown →
  coordinator cleanup → terminal ingress projection.
- Test entry: the public `soma_delegate` functions after one submitted task has
  reached a blocked round.
- Code boundary: task lookup, forwarded status, cancellation waiters, and
  terminal reply handling in `apps/soma_actor/src/soma_delegate.erl`.
  Status and cancel handling live in `soma_delegate_coordinator.erl`.
- Responsibility owner: the ingress owns task-id routing. The coordinator owns
  task state and the active-round cancellation decision.
- Test: `test_status_and_cancel_route_by_task_id` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 4 — coordinator and round-worker crashes do not kill ingress

- Call chain: delegate submit → temporary coordinator → temporary round
  worker → injected process exit → owner monitor `DOWN` handling →
  bounded status → later ingress request.
- Test entry: `soma_delegate:submit/1`. The case kills the discovered child pid
  only for fault injection, then checks the same registered ingress pid with
  `status/1` and a fresh submit.
- Code boundary: temporary child specifications in the three delegate
  supervisors, coordinator monitor handling in `soma_delegate.erl`, and worker
  monitor handling in `soma_delegate_coordinator.erl`.
- Responsibility owner: OTP supervisors isolate child failure.
  `soma_delegate` and `soma_delegate_coordinator` turn matching `DOWN` signals
  into task data.
- Test: `test_coordinator_and_round_worker_crashes_leave_ingress_responsive` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 5 — production action crosses the full process spine

- Call chain: `soma_delegate:submit/1` → ingress →
  `soma_delegate_coordinator` → `soma_delegate_round_worker` →
  `soma_llm_call:start_owned/1` → fixed LLM result →
  `soma_run_sup:start_run/1` → `soma_run` →
  `soma_tool_call:start/1` → test tool → round commit → terminal
  projection.
- Test entry: `soma_delegate:submit/1` with one fixed round whose action is an
  already-canonical two-step list. The event journal supplies the exact
  `run.started` steps and the tool-worker identities.
- Code boundary: coordinator-to-worker dispatch in
  `apps/soma_actor/src/soma_delegate_coordinator.erl`, child ownership in
  `soma_delegate_round_worker.erl`, and the additive owned start in
  `apps/soma_runtime/src/soma_llm_call.erl`.
- Responsibility owner: the round worker owns decision and action children.
  The unchanged runtime owns flat step and tool execution.
- Test: `test_delegate_action_crosses_full_worker_run_tool_spine` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 6 — coordinator and worker own different child layers

- Call chain: delegate submit → active coordinator round record → round
  worker LLM phase → round worker run phase → cancellation and timer
  cleanup.
- Test entry: `soma_delegate:submit/1` with deterministic barriers in both
  phases. The case reads `process_info/2` and `sys:get_state/1` to inspect real
  links, monitors, timers, and owner records.
- Code boundary: active-round ownership in
  `apps/soma_actor/src/soma_delegate_coordinator.erl`, temporary-child
  ownership in `soma_delegate_round_worker.erl`, and
  `soma_llm_call:start_owned/1`.
- Responsibility owner: the coordinator owns only the round worker and overall
  round bound. The round worker owns LLM and run children with their phase
  timers and cancel paths.
- Test: `test_coordinator_and_round_worker_split_child_ownership` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 7 — sequential rounds commit before a distinct next worker

- Call chain: first worker result → coordinator identity and payload
  validation → state commit → worker and timer clear → second worker
  start → second result.
- Test entry: `soma_delegate:submit/1` with two fixed rounds whose barriers
  report their pids and observe the snapshot supplied to the second round.
- Code boundary: valid-result transition and next-round start order in
  `apps/soma_actor/src/soma_delegate_coordinator.erl`.
- Responsibility owner: the coordinator is the sole cross-round sequencer and
  commit authority.
- Test: `test_sequential_rounds_commit_before_distinct_next_worker` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 8 — round snapshots are bounded and task-only

- Call chain: coordinator-owned task state → snapshot projection and size
  check → temporary round worker → canonical action containing an opaque
  handle → `soma_run` → handle-aware test tool.
- Test entry: `soma_delegate:submit/1` with forbidden sentinel fields at the
  upstream fixture boundary and a lease adapter that returns distinct raw and
  opaque values. The fixed-round callback records the actual snapshot.
- Code boundary: snapshot construction in
  `apps/soma_actor/src/soma_delegate_coordinator.erl`, worker input state in
  `soma_delegate_round_worker.erl`, and lease separation in
  `soma_delegate_lease_guard.erl`.
- Responsibility owner: the coordinator owns context projection for AS.5a.
  The lease guard owns raw leases. The runtime tool path receives only opaque
  handles.
- Test: `test_round_snapshot_is_bounded_task_only_and_handle_scoped` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 9 — only the active worker can commit one round result

- Call chain: blocked active round → internal result mailbox → complete
  identity match → result validation → exactly-once commit.
- Test entry: production submit starts the real coordinator and worker. The
  case then sends stale, duplicate, task-mismatched, round-mismatched,
  worker-mismatched, and capability-mismatched result messages. Those cases
  cannot be produced by an honest current worker. It compares the full
  `sys:get_state/1` term before and after each row, then commits one valid
  result exactly once.
- Code boundary: result-message matching, payload validation, and commit in
  `apps/soma_actor/src/soma_delegate_coordinator.erl`.
- Responsibility owner: the coordinator owns the active round identity and is
  the only process allowed to commit cross-round state.
- Test: `test_round_result_identity_rejects_stale_duplicate_and_mismatched_messages`
  in `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 10 — pre-stateful crash and timeout become bounded round failures

- Call chain: delegate submit → temporary worker before unsafe dispatch →
  worker monitor `DOWN` or coordinator round timer → bounded failure commit
  → optional later distinct round.
- Test entry: `soma_delegate:submit/1` in a two-row fixture. One row crashes the
  worker before action start. The other blocks its LLM until the coordinator
  timeout owns cancellation.
- Code boundary: pre-stateful `DOWN`, overall round timeout, and forced-stop
  handling in `apps/soma_actor/src/soma_delegate_coordinator.erl`.
  The temporary worker specification lives in
  `soma_delegate_round_sup.erl`.
- Responsibility owner: the coordinator classifies worker loss from its
  dispatch marker and remains available for a later explicit round.
- Test: `test_pre_stateful_worker_crash_and_timeout_are_bounded` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 11 — lost unsafe result reaches in_doubt without replay

- Call chain: delegate action → unsafe descriptor classification → dispatch
  marker → one `soma_run` → one state `soma_tool_call` → round-worker
  death before result delivery → coordinator `in_doubt` cleanup.
- Test entry: `soma_delegate:submit/1` with one hanging state test tool. The case
  waits for its sole `tool.started` event before killing the round worker. It
  never kills or starts a run directly.
- Code boundary: unsafe dispatch reporting in
  `apps/soma_actor/src/soma_delegate_round_worker.erl`, conservative worker
  loss handling in `soma_delegate_coordinator.erl`, and linked cleanup through
  the unchanged `soma_run` terminate path.
- Responsibility owner: the coordinator owns the mutation and unknown-outcome
  ledger. It forbids replacement after an unsafe outcome is lost.
- Test: `test_lost_state_result_is_in_doubt_without_replacement` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 12 — task leases stay stable and release exactly once

- Call chain: delegate submit → one lease guard → configured acquisitions
  → repeated round snapshots → coordinator cleanup or owner monitor
  `DOWN` → adapter releases.
- Test entry: `soma_delegate:submit/1` in a table over success, failure,
  timeout, cancellation, and coordinator crash. A hermetic adapter records all
  acquire and release callbacks.
- Code boundary: lease acquisition and release in
  `apps/soma_actor/src/soma_delegate_lease_guard.erl`, adapter contract in
  `soma_delegate_lease_adapter.erl`, and cleanup calls in
  `soma_delegate_coordinator.erl`.
- Responsibility owner: the coordinator owns the task lease lifetime. The
  guard owns raw terms and guarantees one release after owner death.
- Test: `test_task_leases_are_stable_and_released_once_for_all_outcomes` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 13 — cancellation removes every active child and stops later rounds

- Call chain: `soma_delegate:cancel/1` → ingress route → coordinator cancel
  → round worker cancel → LLM kill, or run cancel → tool-worker and OS
  teardown → run and round-child removal → one terminal cancellation.
- Test entry: public cancel in a two-row fixture. The LLM row blocks a real
  `soma_llm_call`. The action row runs a generated CLI helper that records its
  OS pid before blocking. Each row asserts every listed child is dead before
  the reply, exactly one terminal cancellation exists, and no later round
  starts.
- Code boundary: deferred cancel reply in
  `apps/soma_actor/src/soma_delegate.erl`, coordinator cleaning transition in
  `soma_delegate_coordinator.erl`, and phase cleanup in
  `soma_delegate_round_worker.erl`.
- Responsibility owner: the coordinator owns task cancellation and prevents a
  next round. The round worker and unchanged runtime own descendant teardown.
- Test: `test_cancel_tears_down_llm_run_tool_and_os_children_once` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 14 — concurrent tasks keep all mutable state disjoint

- Call chain: two distinct submit calls → two temporary coordinators → two
  lease guards → two active round workers → cancellation of one route →
  other task continues.
- Test entry: public submit and cancel functions with two blocked fixed-round
  fixtures. The case inspects each coordinator and guard only after finding
  them by their bounded task identity.
- Code boundary: request and task routing in
  `apps/soma_actor/src/soma_delegate.erl`, per-task state in
  `soma_delegate_coordinator.erl`, and lease tables in
  `soma_delegate_lease_guard.erl`.
- Responsibility owner: one coordinator and one lease guard own each task.
  The ingress never combines their context, counters, workers, or handles.
- Test: `test_concurrent_tasks_isolate_state_workers_and_leases` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 15 — one cleanup transition removes all task-local reasoning state

- Call chain: table-driven terminal round outcome → coordinator `cleaning`
  entry → child teardown → lease release → bounded event and projection
  → coordinator exit → later fresh submit.
- Test entry: `soma_delegate:submit/1` across success, failure, timeout,
  cancellation, and `in_doubt` fixtures. Each row then submits a new request
  carrying different sentinels.
- Code boundary: the single cleaning transition in
  `apps/soma_actor/src/soma_delegate_coordinator.erl`, terminal storage in
  `soma_delegate.erl`, and lease cleanup in
  `soma_delegate_lease_guard.erl`.
- Responsibility owner: the coordinator owns normal terminal cleanup. Its
  process lifetime is the boundary for objective, transcript, budgets,
  mutations, and capabilities.
- Test: `test_terminal_cleanup_scrubs_task_state_before_fresh_request` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 16 — public delegate events are stable, bounded, and scrubbed

- Call chain: delegate lifecycle transition →
  `soma_delegate_event:append/5` → allowlisted event construction and size
  check → `soma_event_store:append/2` → correlation query and trace.
- Test entry: `soma_delegate:submit/1` with oversized and forbidden sentinels in
  every task-local field. The case filters only `delegate.*` events from the
  public event store.
- Code boundary: event schema, recursive scrubber, fallback summary, and
  `max_bytes/0` in `apps/soma_actor/src/soma_delegate_event.erl`.
  Event calls live in `soma_delegate.erl` and
  `soma_delegate_coordinator.erl`.
- Responsibility owner: `soma_delegate_event` is the sole authority for public
  delegate lifecycle data. The event store retains generic append semantics.
- Test: `test_delegate_events_are_bounded_stable_and_scrubbed` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 17 — delegate completion preserves existing public result contracts

- Call chain: completed delegate task → unchanged `soma_service:invoke/1`
  result path → unchanged local `soma_cli_server` run path → unchanged
  `soma_actor:send/2` result path.
- Test entry: one completed production delegate task followed by representative
  public echo work through the service, a real local CLI socket, and a direct
  actor. The case compares their established result shapes.
- Code boundary: additive delegate modules and child entries in
  `apps/soma_actor/src/soma_actor_sup.erl` and
  `apps/soma_actor/src/soma_actor.app.src`. Existing service, CLI, actor, run,
  and result code is outside the modifiable boundary.
- Responsibility owner: the delegate substrate is additive. Existing owners
  retain their result contracts and their full suites remain in the merge gate.
- Test: `test_completed_delegate_preserves_existing_result_contracts` in
  `apps/soma_actor/test/soma_delegate_SUITE.erl`.

### Criterion 18 — AS.5a contract maps every criterion to one hermetic proof

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/contracts/AS.5a-test-contract.md` because the
  required behavior is the durable guarantee-to-proof map.
- Code boundary: `docs/contracts/AS.5a-test-contract.md` and
  `apps/soma_actor/test/soma_as5a_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the test contract. The EUnit
  pin prevents missing, duplicate, or non-hermetic criterion mappings.
- Test: `test_as5a_contract_maps_every_criterion_to_one_hermetic_test` in
  `apps/soma_actor/test/soma_as5a_contract_doc_tests.erl`.

## Risks & trade-offs

- This issue adds several OTP processes around one delegated task. The extra
  mailboxes and monitors cost more than keeping the loop in `soma_actor`. They
  also make task lifetime, cancellation, and crash ownership observable.
- The fixed-round sequence is production-compiled test support. It must remain
  inaccessible from config, Lisp, and sockets. Leaving it as a user-facing
  planner would create a second action protocol beside #233.
- Linking a round worker to its run gives abnormal worker death a cleanup path.
  `soma_run` traps exits, so the round worker must still remove normal terminal
  run children. Tests need to cover both paths.
- A lease guard makes coordinator-kill cleanup possible, but it is another
  temporary process that can fail. Guard failure before release should fail
  closed and surface bounded task data. Durable or distributed lease recovery
  remains outside this issue.
- Conservative `in_doubt` classification can report uncertainty even when a
  state tool made no mutation. That is safer than replaying work after its
  terminal result was lost. #233 may add explicit reconciliation, not automatic
  retry.
- `auto_resume => false` means an interrupted delegated action is not recovered
  by the generic runtime boot path. Durable delegate recovery needs the full
  #233 event and result protocol and is not part of AS.5a.
- The 65,536-byte snapshot cap is a byte bound, not a model-token budget. #233
  must add token-aware projection without weakening this ownership boundary.
- The ingress keeps one bounded terminal projection and request route per task.
  Individual entries are bounded, but total index compaction and retention are
  still separate log/index work.
- Public delegate events omit child identities even though internal tests need
  them. Operators correlate detailed action work through task, correlation,
  round, and run ids instead of process-local terms.
