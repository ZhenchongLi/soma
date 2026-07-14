# [cc] RS.1b runtime service core: dedupe, scope, lifecycle, in_doubt

## Current state

RS.1a added `soma_service_envelope:normalize/1`. It accepts the versioned
`invoke` map and returns one canonical envelope. A tool operation contains one
canonical step. A steps operation contains the existing source-ordered step
list. Scope entries remain binaries. The normalizer starts no process and does
not make an admission decision.

There is no runtime service owner yet. `soma_actor_sup` starts
`soma_actor_registry` and `soma_actor_child_sup`. Actor instances are temporary
children under the child supervisor. No permanent actor-layer process accepts
an invoke envelope, owns a request-id index, tracks a service task, or enforces a
service deadline.

`soma_actor` shows the ownership pattern this slice needs. It starts a run with
`session_pid => self()`, monitors the run, translates run messages into task
states, and forwards cancellation to the run. That module also contains LLM and
proposal work. The new service must not call that path because an invoke
envelope already contains the decided operation.

`soma_run` already owns sequential step execution. It resolves descriptors in
source order, starts one `soma_tool_call` worker per step, records each output,
and resolves both `from_step` forms from committed outputs. Its timeout and
cancel paths kill the BEAM worker and the external CLI process. A terminal run
sends one of `run_completed`, `run_failed`, `run_timeout`, or `run_cancelled` to
its owner.

The run journal is close to what service recovery needs. `run.started` stores
the canonical steps and an allowlisted `run_options` map. That map currently
contains only `run_id`, optional `session_id`, and optional `correlation_id`.
It does not contain a service task id, request id, envelope hash, output limit,
absolute deadline, or owner-recovery marker.

`soma_event_store` replays a `disk_log` into its in-memory index. `all/1` and
`by_run/2` expose that trail in append order. `interrupted_runs/1` finds a
`run.started` trail with no terminal run event. The current runtime boot path
hands every such run to `soma_run_resume_executor`. That executor appends
`run.failed` for an unsafe in-flight state step. Service-owned runs need a
different terminal classification, so runtime boot must leave those runs for
the service owner.

`soma_run_resume_plan:plan/2` already detects an in-flight step and returns
`{unsafe, StepId}` when its descriptor is not safe to repeat. The descriptor
rule is private in that module. It treats `reader`, `identity`, and any
idempotent descriptor as safe. RS.1b needs the same rule without copying it into
`soma_actor`.

`soma_policy:check/2` is the existing tool-name allowlist authority. It accepts
a `run_steps` proposal and a policy whose allowed tools are atoms or `all`.
Invoke scope entries are binaries. A service adapter must project those binaries
onto names already present in `soma_tool_registry`. It must never create an atom
from a scope entry.

## Approach

Add `soma_service` to `soma_actor` as a locally registered `gen_server`. The
root actor supervisor starts it as a permanent worker beside
`soma_actor_child_sup`. The production `start_link/0` reads the event store from
`soma_sup` and reads `service_policy` from the application environment. The
default policy is `#{allowed_tools => []}`. A `start_link/1` form accepts an
injected store and policy for isolated recovery tests.

The public service surface for this slice is asynchronous and process-owned:

- `invoke` accepts an envelope and returns an immutable accepted task handle or
  an already-terminal task map.
- `status` reads the current task map.
- `cancel` asks the service to cancel a running task.

Keep pid-taking forms for test fixtures and future adapters. Production wrappers
address the registered service. An accepted handle contains `task_id`,
`request_id`, and `status => accepted`. A status read may return `running` or
one terminal state. A successful terminal map adds `result => Outputs`, where
`Outputs` is the exact step-id-to-output map returned by `soma_run`. A failed or
rejected terminal map adds one bounded typed reason. The terminal states are
`succeeded`, `failed`, `rejected`, `cancelled`, and `in_doubt`.

Normalize inside the service process before admission. Convert a tool operation
to a one-element step list. Use a steps operation without changing its order.
Do not call `soma_actor`, `soma_llm_call`, proposal normalization, or any planner.

Hash the complete normalized envelope with SHA-256 over
`term_to_binary(Envelope, [deterministic])`. Add `crypto` to the direct
`soma_actor` application dependencies. Keep the 32-byte digest in service state
and in the durable trail. Do not store the full envelope in a dedupe entry.

The service gen_server serializes request-id decisions. Its index maps one
binary `request_id` to the digest, immutable accepted handle, task id, run id,
current state, monitor, and deadline timer. A matching digest returns the
original accepted handle while work is active. It returns the stored terminal
map after completion. A different digest returns
`{error, request_id_conflict}`. That branch starts no run and appends no new
task event.

Record bounded service lifecycle events in the same event store:

- `service.task.accepted` records `task_id`, `run_id`, `request_id`, the digest,
  and the safe numeric budgets.
- `service.task.running` records the same stable ids after the run starts.
- `service.task.cancel_requested` and `service.task.deadline_expired` record
  which owner action selected the terminal mapping.
- `service.task.terminal` records the stable ids, terminal status, and a bounded
  reason when one exists.

Do not place successful output in a service lifecycle event. The existing
`step.succeeded` trail is the source for reconstruction. A service restart can
call `soma_run_resume:reconstruct/2` to recover the exact outputs. This keeps a
second unbounded result copy out of the service event.

Append `service.task.accepted` before admission. A policy rejection can then be
deduplicated after restart even though it has no `run.started` event. If the
service dies after that event but before `run.started`, recovery can prove that
no run crossed the start boundary. It records a bounded
`service_interrupted_before_start` failure instead of guessing that a tool ran.

For an envelope with `scope`, build the policy allowlist by comparing each
binary entry with `atom_to_binary(Name, utf8)` for names returned by
`soma_tool_registry:list_tools/0`. Unknown entries add nothing. Pass the
canonical steps and that projected allowlist to `soma_policy:check/2`. For an
envelope without `scope`, pass the configured service policy unchanged. This
makes the caller-supplied scope authoritative when present. It makes the
configured policy the fallback when scope is absent. `soma_policy:check/2`
remains the only function that decides tool-name membership.

A policy rejection creates a terminal task with `status => rejected` and a
typed `{policy_rejected, Reason}` reason. It records
`service.task.terminal` and starts no run. A duplicate of that envelope returns
the same terminal map from the durable index.

For an allowed task, mint a service task id and a distinct run id. Start the run
under `soma_run_sup` with `session_pid => self()`. Pass the canonical steps,
event store, optional correlation id, and service journal metadata. Extend
`soma_run`'s durable option allowlist with only these values:

- `task_id`
- `request_id`
- `envelope_hash`
- `max_output_bytes` when present
- `deadline_at_ms` when present
- `auto_resume => false`

The absolute deadline is `system_time(millisecond) + deadline_ms`. A restart
re-arms only the remaining interval. The generic `auto_resume` coordinator
skips a run whose journal says `false`. Missing values keep the current runtime
default. The service then owns recovery for its runs without adding an actor
reference to `soma_runtime`.

Monitor every started or adopted run. Keep the run pid and monitor ref only in
service memory. On a normal terminal message, demonitor with `[flush]`, cancel
the deadline timer, and ask `soma_run_sup` to terminate the now-terminal child.
Only then publish the service terminal state. This prevents a terminal service
task from retaining a live run process. Ignore terminal messages and `DOWN`
messages that do not match the current run and monitor.

Add a small owner-reattachment seam to the runtime without changing step
execution. `soma_run_sup` can scan its current dynamic children for a run id.
`soma_run` exposes a bounded identity read and an owner-adoption call in every
state. A restarted service first adopts a matching live nonterminal run and
monitors the same pid. It does not start a replacement. This covers a service
process restart while the runtime tree remains alive. Existing session and actor
starts keep their current behavior.

When no live run exists, recover from the event trail. First honor an existing
`service.task.terminal` event. Otherwise inspect the reconstructed run:

- A terminal run trail becomes the matching service terminal state.
- A completed run becomes `succeeded` after the output limit check.
- A failed run becomes `failed` with a bounded summary. A raw crash stack stays
  in the run trace and does not enter the service terminal map.
- A run timeout becomes `failed` with a typed timeout reason.
- A cancelled run becomes `cancelled` after a public cancel marker. It becomes
  `failed` with `deadline_exceeded` after a deadline marker.
- A nonterminal trail enters `soma_run_resume_plan:plan/2`.

Extract the descriptor-only rule into
`soma_run_resume_safety:descriptor_safe/1` under `soma_runtime`.
`soma_run_resume_plan` resolves the live descriptor and calls this helper. An
unresolvable descriptor remains unsafe. Service recovery calls the production
resume plan rather than recreating in-flight detection.

On `{unsafe, StepId}`, record `status => in_doubt` with a bounded reason that
names the step id. Append only `service.task.terminal`. Do not call the resume
executor. Do not append `run.failed`. Do not start a replacement run.

On `{resume, _}`, call `soma_run_resume_executor:resume/3` with the service as
owner. Monitor the returned run pid and keep the recovered task `running`. The
resumed run keeps its original run id, committed outputs, pending suffix, and
correlation id. It emits `run.resumed` and no second `run.started`.

Keep the existing non-service resume executor behavior. A normal runtime resume
may still append `run.failed` for an unsafe run. The new `auto_resume => false`
filter is what prevents that executor path from claiming a service-owned trail
before `soma_service` starts.

Treat `max_output_bytes` as the external-term size of the whole `Outputs` map.
Use `erlang:external_size/1` so the check does not allocate a second encoded
copy. A size above the cap produces `status => failed` with
`reason => max_output_bytes_exceeded`. Do not truncate and do not retain the
result in the task map.

The service owns deadline selection. When its timer fires, append
`service.task.deadline_expired` and send `cancel` to the current run. Wait for
the run's `run_cancelled` message because the run kills the tool worker and any
external OS process before that message. Remove the terminal run child. Then
publish `status => failed` with `reason => deadline_exceeded` under the same
service pid.

Public cancellation follows the same owner path. Append
`service.task.cancel_requested`, send `cancel`, and wait for
`run_cancelled`. Publish `status => cancelled` only after the run completes its
worker and OS-process teardown. Do not map this path to `failed`.

All state changes pass through one transition helper. The allowed forward edges
are `accepted` to `running` or `rejected`, then `running` to one terminal state.
Recovery may move a reconstructed active task to `running` or `in_doubt`.
Terminal entries never change. The immutable accepted handle is separate from
the current status map, so an active duplicate returns the same handle even
after the internal state reaches `running`.

Put the process tests in one Common Test suite under `soma_actor`. Add a small
test-only hanging state tool for the unsafe interruption case. Generate CLI
stub executables inside the lifecycle cases. The stubs write their OS pid to a
test path before sleeping. This lets the test prove process death directly
after deadline and cancellation.

## Acceptance criteria → tests

### Criterion 1 — the supervised service restarts and serves again

- Call chain: `application:ensure_all_started(soma_actor)` →
  `soma_actor_app:start/2` → `soma_actor_sup:init/1` →
  `soma_service:start_link/0` → service request handling.
- Test entry: application boot. The case kills the supervised service pid,
  waits for a distinct replacement pid, and submits an allowed echo invocation
  to that replacement. Before the kill, a slow invocation lets the case assert
  that the service process monitors the owned run.
- Code boundary: `apps/soma_actor/src/soma_actor_sup.erl`,
  `apps/soma_actor/src/soma_service.erl`, and
  `apps/soma_actor/src/soma_actor.app.src`.
- Responsibility owner: `soma_actor_sup` owns the permanent service child.
  `soma_service` owns invocation state, monitors, and timers.
- Test: `test_supervised_service_restarts_and_serves_again` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 2 — one tool succeeds through the production path without an LLM worker

- Call chain: normalized envelope → `soma_service:invoke` → envelope
  normalization → dedupe → `soma_policy:check/2` → `soma_run_sup:start_run/1`
  → `soma_run` → `soma_tool_call:start/1` → echo tool → service terminal
  handling.
- Test entry: `soma_service:invoke` with a canonical one-tool envelope. No
  service, run, or worker layer is bypassed. The case asserts the exact output
  map and the `run.started` plus `tool.started` trail. A call trace on
  `soma_llm_call:start/1` must remain empty for the whole invocation.
- Code boundary: invoke dispatch and run ownership in
  `apps/soma_actor/src/soma_service.erl`, plus the existing runtime start path.
- Responsibility owner: `soma_service` owns the task. `soma_run` and
  `soma_tool_call` own execution. No module in this chain owns an LLM call.
- Test: `test_single_tool_invocation_runs_without_llm_worker` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 3 — an oversized task result fails with a typed reason

- Call chain: service invoke → run completion with exact outputs →
  `soma_service` output-size check → bounded failed terminal task.
- Test entry: `soma_service:invoke` with echo output larger than a small
  `max_output_bytes` cap. The case asserts that the terminal map has no result
  field.
- Code boundary: result finalization and terminal event construction in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service` owns the task-result budget. The run
  still owns the tool result and execution trail.
- Test: `test_oversized_result_fails_with_max_output_reason` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 4 — flat plans preserve source order and from_step data

- Call chain: steps envelope → `soma_service:invoke` → unchanged canonical
  step list → `soma_run` sequential cursor → first `soma_tool_call` → committed
  output → `resolve_args/2` → second `soma_tool_call`.
- Test entry: `soma_service:invoke` with two echo steps. The second step uses a
  bare `from_step` reference to the first. The case reads `step.started` events
  in order and checks that the second output equals the first output.
- Code boundary: operation-to-step conversion in
  `apps/soma_actor/src/soma_service.erl`. Existing sequential and reference
  behavior stays in `apps/soma_runtime/src/soma_run.erl`.
- Responsibility owner: `soma_service` preserves the canonical list.
  `soma_run` owns ordering and output substitution.
- Test: `test_flat_plan_preserves_order_and_from_step_output` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 5 — identical active and terminal duplicates reuse one task

- Call chain: first invoke → normalized-envelope digest → new dedupe entry →
  one run start. Later identical invokes → same request-id entry → original
  accepted handle or terminal map.
- Test entry: `soma_service:invoke` three times with one slow canonical
  envelope. The second call occurs after `tool.started`. The third occurs after
  terminal success. The case asserts that only one matching `run.started`
  event exists.
- Code boundary: digest creation, request-id index lookup, and immutable task
  snapshots in `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: the single `soma_service` gen_server owns atomic dedupe
  decisions.
- Test: `test_identical_duplicate_reuses_running_handle_and_terminal_result` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 6 — a conflicting request id is rejected before another run starts

- Call chain: changed envelope → normalization → digest → existing request-id
  lookup → digest mismatch → `request_id_conflict`.
- Test entry: `soma_service:invoke` after an earlier envelope with the same
  request id has started. The second envelope changes one normalized argument.
  The count of matching `run.started` events must not change.
- Code boundary: the pre-admission dedupe branch in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service` owns request identity and conflict
  rejection before policy or execution.
- Test: `test_conflicting_request_id_rejected_before_new_run` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 7 — run.started journals request identity and the envelope hash

- Call chain: service invoke → digest and task metadata →
  `soma_run_sup:start_run/1` → `soma_run:init/1` → durable
  `run.started` event.
- Test entry: `soma_service:invoke` against a `disk_log` event store. The case
  restarts the store before reading the journal. It recomputes the SHA-256
  digest from the normalized envelope and checks the exact durable value.
- Code boundary: service run options in
  `apps/soma_actor/src/soma_service.erl` and the durable option allowlist in
  `apps/soma_runtime/src/soma_run.erl`.
- Responsibility owner: `soma_run:init/1` is the one journal point for every
  normal run start. `soma_service` supplies only resume-safe metadata.
- Test: `test_run_started_journals_request_id_and_envelope_hash` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 8 — durable restart rebuilds dedupe without another run.started

- Call chain: durable invoke trail → service or application restart →
  `soma_event_store` replay → `soma_service:init/1` index rebuild → live-run
  adoption or terminal reconstruction → duplicate lookup.
- Test entry: `soma_service:invoke` in a disk-backed fixture. The case first
  kills the service during a slow task and proves live-run adoption. It then
  completes the task, restarts the durable store and service, and proves the
  terminal result is reconstructed.
- Code boundary: lifecycle event replay and dedupe rebuild in
  `apps/soma_actor/src/soma_service.erl`, plus bounded run lookup and owner
  adoption in `apps/soma_runtime/src/soma_run_sup.erl` and
  `apps/soma_runtime/src/soma_run.erl`.
- Responsibility owner: the durable event trail is the source of truth.
  `soma_service` rebuilds its in-memory index and never replays an identical
  request as a new run.
- Test: `test_durable_restart_rebuilds_dedupe_without_new_run_started` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 9 — out-of-scope work is rejected through soma_policy

- Call chain: scoped envelope → registered-name projection →
  `soma_policy:check/2` → policy rejection → service rejected terminal event.
- Test entry: `soma_service:invoke` with an echo step and a scope that contains
  another registered tool name. The case traces the service call to
  `soma_policy:check/2`.
- Code boundary: binary-scope projection and admission in
  `apps/soma_actor/src/soma_service.erl`. The allowlist decision remains in
  `apps/soma_actor/src/soma_policy.erl`.
- Responsibility owner: `soma_policy` is the sole tool-name membership rule.
  `soma_service` only adapts validated binary scope to known atom names.
- Test: `test_out_of_scope_invocation_rejected_through_policy` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 10 — unscoped work uses configured policy and fails closed by default

- Call chain: unscoped envelope → service policy selection →
  `soma_policy:check/2` → allowed run or rejected task.
- Test entry: table-driven `soma_service:invoke` calls. One fixture configures
  echo. One uses the empty application default. The default fixture must have
  no `run.started` event.
- Code boundary: policy initialization and unscoped selection in
  `apps/soma_actor/src/soma_service.erl`, plus the default in
  `apps/soma_actor/src/soma_actor.app.src`.
- Responsibility owner: service configuration owns the unscoped fallback.
  `soma_policy` owns the verdict.
- Test: `test_unscoped_invocation_uses_configured_or_empty_default_policy` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 11 — unknown scope entries create no atom

- Call chain: envelope with an unknown binary scope entry → known registry-name
  projection → `soma_policy:check/2` → bounded rejection.
- Test entry: `soma_service:invoke` after preloading the production modules and
  pinning `erlang:system_info(atom_count)`.
- Code boundary: scope adaptation in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service` must compare external binaries with
  existing names. It must not call an atom-creation BIF.
- Test: `test_unknown_scope_entry_does_not_create_atom` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 12 — deadline expiry fails the task and tears down CLI resources

- Call chain: service invoke → `soma_run` → `soma_tool_call` → CLI port →
  service deadline timer → run cancel path → worker and OS-process teardown →
  `run_cancelled` → service failed terminal state.
- Test entry: `soma_service:invoke` with a stub CLI descriptor and a short
  `deadline_ms`. The CLI step itself has a longer timeout. The case pins the
  service pid before and after, reads the worker pid from `tool.started`, reads
  the OS pid from the stub file, and proves all three invocation processes are
  gone after the failed status becomes visible.
- Code boundary: deadline timers and terminal mapping in
  `apps/soma_actor/src/soma_service.erl`, plus terminal run-child cleanup in
  `apps/soma_runtime/src/soma_run_sup.erl`. Existing worker and OS teardown
  stays in `apps/soma_runtime/src/soma_run.erl`.
- Responsibility owner: `soma_service` owns the task deadline. `soma_run` owns
  cancellation of its active invocation resources.
- Test: `test_deadline_exceeded_cleans_run_worker_and_cli_process` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 13 — public cancellation reaches cancelled and tears down CLI resources

- Call chain: `soma_service:cancel` → current task lookup → run `cancel`
  message → `soma_run` worker and OS-process teardown → `run_cancelled` →
  service cancelled terminal state.
- Test entry: service invoke with the sleeping CLI stub, followed by
  `soma_service:cancel` after `tool.started`. The case pins the service pid and
  proves that both the tool worker and the stub OS pid are dead before it reads
  `cancelled`.
- Code boundary: public cancellation and run ownership in
  `apps/soma_actor/src/soma_service.erl`. Existing cancellation teardown stays
  in `apps/soma_runtime/src/soma_run.erl`.
- Responsibility owner: `soma_service` selects the public cancelled outcome.
  The run owns real cleanup.
- Test: `test_service_cancel_cleans_tool_worker_and_cli_process` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 14 — a tool crash is bounded task data and the service stays usable

- Call chain: service invoke → run → crashing `soma_tool_call` → monitored
  `DOWN` at `soma_run` → `run_failed` → bounded service failure. A second
  invoke repeats the normal service-to-run path.
- Test entry: `soma_service:invoke` with the built-in fail tool in crash mode,
  followed by a new echo request to the same service pid. The case caps the
  encoded failed terminal map and asserts that no raw stack is present.
- Code boundary: run-failure normalization and terminal cleanup in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_run` turns the worker crash into run data.
  `soma_service` turns that data into a bounded task summary and remains alive.
- Test: `test_tool_crash_is_bounded_and_service_runs_again` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 15 — lifecycle reads never regress

- Call chain: invoke accepted handle → service running state → one run terminal
  message → immutable terminal state → repeated status reads.
- Test entry: `soma_service:invoke` with a slow reader step, followed by polling
  `soma_service:status` before and after completion. The accepted invoke handle,
  a running read, and repeated terminal reads form the asserted sequence.
- Code boundary: transition validation and status snapshots in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: the service task table owns monotonic lifecycle state.
- Test: `test_lifecycle_reads_are_monotonic` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 16 — interrupted unsafe state work recovers as in_doubt

- Call chain: service invoke → non-idempotent state tool starts → simulated
  owner and run interruption → durable store replay → service recovery →
  `soma_run_resume_plan:plan/2` → unsafe verdict → service `in_doubt` terminal
  event.
- Test entry: a real invocation through `soma_service:invoke` using the
  test-only hanging state tool. The fixture stops the service, run, worker, and
  store before restarting from the same log. It asserts that no new run child,
  `run.resumed`, or `run.failed` event appears.
- Code boundary: recovery classification in
  `apps/soma_actor/src/soma_service.erl`, descriptor safety in
  `apps/soma_runtime/src/soma_run_resume_safety.erl`, and owner-managed
  auto-resume filtering in `apps/soma_runtime/src/soma_run_auto_resume.erl`.
- Responsibility owner: the runtime resume plan owns repeat-safety facts.
  `soma_service` owns the `in_doubt` task meaning and must not synthesize a run
  failure.
- Test: `test_unsafe_interrupted_state_invocation_recovers_in_doubt` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 17 — interrupted reader work resumes from the durable trail

- Call chain: service invoke → reader tool starts → simulated owner and run
  interruption → durable replay → service recovery → resume plan safe verdict
  → `soma_run_resume_executor:resume/3` → `soma_run_sup` → resumed tool worker
  → service success.
- Test entry: a real slow reader invocation through `soma_service:invoke` in
  the same disk-backed interruption fixture used for recovery tests. It asserts
  one `run.resumed`, no second `run.started`, and a successful state rather than
  `in_doubt`.
- Code boundary: service recovery and resumed-run monitoring in
  `apps/soma_actor/src/soma_service.erl`, plus the shared safety helper and the
  existing resume executor under `apps/soma_runtime/src/`.
- Responsibility owner: `soma_run_resume_plan` owns the safe verdict.
  `soma_run_resume_executor` owns resumed execution. `soma_service` restores
  the task owner and lifecycle.
- Test: `test_interrupted_reader_invocation_resumes_after_restart` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 18 — recovery shares descriptor safety and keeps dependencies one-way

- Call chain: service recovery → `soma_run_resume_plan:plan/2` → descriptor
  lookup → `soma_run_resume_safety:descriptor_safe/1`. The dependency check
  uses `none (compile-time assertion)`.
- Test entry: direct calls to the pure descriptor helper pin its safe and unsafe
  table. Compiled import checks pin the service-to-plan-to-helper chain. An
  application manifest and runtime source scan pin the absence of a reverse
  actor dependency. The restart behavior itself is covered by Criteria 16 and
  17.
- Code boundary: `apps/soma_runtime/src/soma_run_resume_safety.erl`,
  `apps/soma_runtime/src/soma_run_resume_plan.erl`,
  `apps/soma_actor/src/soma_service.erl`, and
  `apps/soma_runtime/src/soma_runtime.app.src`.
- Responsibility owner: `soma_runtime` owns descriptor repeat safety.
  `soma_actor` may call down to it. Runtime code must not name the actor app.
- Test: `test_recovery_uses_shared_descriptor_safety_without_reverse_dependency`
  in `apps/soma_actor/test/soma_service_boundary_tests.erl`.

### Criterion 19 — the RS.1b contract maps every criterion to its proof

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/contracts/RS.1b-test-contract.md` and checks one
  criterion heading and one full module-function name for all nineteen issue
  criteria.
- Code boundary: `docs/contracts/RS.1b-test-contract.md` and
  `apps/soma_actor/test/soma_rs1b_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the durable guarantee-to-proof
  map for RS.1b.
- Test: `test_rs1b_contract_maps_every_criterion_to_proving_case` in
  `apps/soma_actor/test/soma_rs1b_contract_doc_tests.erl`.

## Risks & trade-offs

- The service output cap applies to the task result returned by the service.
  `soma_run` still records each successful step output in its existing event.
  Changing that core event contract would change run execution and trace
  behavior outside this issue.
- SHA-256 keeps dedupe entries and lifecycle events small. It introduces a
  direct `crypto` dependency. A hash collision is theoretically possible. The
  service does not persist the full normalized envelope as a second comparison
  source.
- The deterministic external-term encoding is stable for the current runtime
  contract. A future envelope version or an OTP migration that changes encoded
  bytes needs an explicit hash-version field before mixed-version logs are
  supported.
- Rebuilding the request index scans the event log at service start. This keeps
  the durable log as the source of truth. Startup cost grows with the log until
  the separate compaction and bounded-index work lands.
- A caller-supplied scope replaces the configured fallback policy. This matches
  the issue's separate rule for unscoped requests. A later authentication layer
  must ensure that only the trusted upstream can assert that scope.
- Live-run adoption adds a bounded owner-change call to `soma_run`. It avoids
  duplicate execution after a service-only restart. It also adds a race between
  trail inspection and a run reaching terminal state. The adoption result and a
  second terminal-trail check must close that race without starting a new run.
- `deadline_at_ms` uses wall-clock time so it survives a VM restart. A system
  clock jump can shorten or extend the remaining interval. A monotonic timestamp
  cannot be compared across VM lifetimes.
- Service-owned trails opt out of generic boot auto-resume. If the marker is
  omitted from a new service start path, runtime boot could claim the run before
  the service and apply the older unsafe-failure behavior. The journal test and
  boundary test must pin this marker.
- The generic resume executor still maps unsafe work to `run.failed`. The
  service maps the same unsafe verdict to `in_doubt` without calling that
  executor branch. Keeping one descriptor helper limits rule drift, but the two
  owners intentionally retain different terminal meanings.
- A crash after `service.task.accepted` and before `run.started` sacrifices that
  request rather than retrying it. The trail proves that no run began, so the
  result is a safe bounded failure rather than `in_doubt`. Persisting the whole
  envelope to retry that gap would duplicate the run journal and enlarge the
  service event.
