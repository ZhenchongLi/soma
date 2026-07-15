# [cc] soma.delegate AS.5: optional bounded multi-round tool-observation loop

## Current state

AS.3 already proves a bounded reader-only loop in `soma_actor`. It builds a
policy-filtered catalog prompt, starts one LLM worker per round, runs accepted
reader steps through `soma_run -> soma_tool_call`, and feeds bounded run
observations into the next call. AS.5 does not change that mode or move a loop
into `soma_run`.

AS.5a added a separate production boundary for delegated work.
`soma_delegate:submit/1` deduplicates a request id and starts one temporary
`soma_delegate_coordinator`. The coordinator owns cross-round state and starts
one temporary `soma_delegate_round_worker` at a time. The worker owns its LLM
or run child, monitor, phase timer, and cancellation path. A state action still
reaches the unchanged `soma_run -> soma_tool_call` spine. Coordinator loss,
worker loss, cancellation, and an unsafe lost result already become bounded
task data.

The AS.5a path is scaffolding rather than an adaptive production loop. The raw
task map may carry `round_sequence`, `lease_requests`, functions, and extra
fields. The coordinator copies `round_sequence` into its state. Each sequence
entry supplies both an LLM directive and preselected `action_steps`. The round
worker discards the successful model result and executes those preselected
steps. There is no prompt projector, proposal admission chain, task capability
gate, or tool-schema intersection.

The coordinator has placeholder maps for budgets, usage, mutations, unknown
outcomes, and recent round data. It does not enforce round, LLM-call, tool-call,
prompt-token, or task-deadline budgets. A failed or timed-out action is terminal
instead of becoming the next round's observation. Its snapshot has a
65,536-byte term cap, but that is not a model context budget.

`soma_delegate_event` is the sole builder for `delegate.*` events and already
enforces a 4096-byte deterministic external-term cap. Its allowlist currently
records lifecycle phase, status, reason class, and ledger counts. It does not
record adaptive decision verdicts, action run identities, observation
references, or terminal safety state.

Ingress terminal projections are currently capped at 512 bytes and retain only
`status`, optional `round`, and a reason class. `rejected` is not an accepted
terminal status. There is no public `result`, artifact list, safety ledger,
usage map, or trace reference. Oversized observations have no task artifact
store or slice operation.

The reusable admission pieces already exist. `soma_proposal:normalize/1`
validates model proposal maps. `soma_policy:check/2` applies the global
tool-name allowlist. `soma_tool_registry:catalog/0` exposes only model-facing
schemas. `soma_llm_call:start_owned/1` gives the round worker atomic LLM-child
ownership. The OpenAI-compatible fixed-response callback can inspect a built
request without opening a socket. Provider parsing does not yet retain reported
prompt-token usage.

## Approach

Keep the AS.5a ownership tree and replace its preselected round work with one
adaptive protocol. A successful model response is parsed into the existing
proposal grammar. `run_steps` is a non-terminal action in delegate mode. Its
bounded observation is committed before the next round worker starts. `reply`
is terminal success and its `text` becomes the public `result` unchanged.
`reject` is terminal rejection. `ask` and `actor_message` are outside the
delegate capability surface and fail task capability admission. No new Lisp or
socket form is added.

Add a strict request boundary, preferably `soma_delegate_request:normalize/1`,
and call it from `soma_delegate:submit/1` before dedupe or coordinator startup.
The normalized map has only these top-level keys:

- `request_id`
- `correlation_id`
- `objective`
- `output_contract`
- `capability_scope`
- `resource_handles`
- `artifacts`
- `budgets`

Reject unknown top-level keys rather than dropping them. Recursively reject
pids, ports, references, functions, improper lists, raw lease shapes, provider
or credential fields, and product conversation fields. All forbidden rows
return the same bounded `{error, invalid_delegate_request}` result. The check
runs before task-id minting and before
`soma_delegate_coordinator_sup:start_coordinator/1`.

Keep trusted execution configuration separate from that normalized map.
`soma_delegate` may read the global policy and delegate model configuration
from application-owned options. The coordinator start map should hold the
normalized request under one `request` key and trusted runtime options under a
different key. Provider credentials, model responders, raw lease fixtures, and
process terms must never enter the request, coordinator snapshot, prompt, or
public event. Existing AS.5a tests that put `round_sequence` or
`lease_requests` in the request must move those fixtures into the test-owned
runtime configuration. The fixed-response responder remains a direct Erlang
test seam outside the request and is never loaded from Lisp, config files, or a
socket.

Add a small pure capability module such as
`soma_delegate_capability`. It normalizes the task's tool-name scope without
creating atoms. It computes model-visible schemas from
`soma_tool_registry:catalog/0` filtered by both the global policy and task
scope. It also checks a normalized proposal against the same task scope. This
single intersection must own both prompt visibility and spend-time capability
admission so the two rules cannot drift.

Each model reply follows one admission function in the round worker:

```text
provider result
  -> Lisp/proposal decoding
  -> soma_proposal:normalize/1
  -> soma_policy:check/2
  -> soma_delegate_capability:check/2
  -> terminal projection or soma_run_sup:start_run/1
```

Do not copy either existing gate. A normalization error terminates as `failed`.
A global-policy rejection or task-capability rejection terminates as
`rejected`. All three outcomes happen before `soma_run_sup:start_run/1`, so no
`run.started` event can exist. An admitted `run_steps` action is passed to the
existing runtime as canonical flat steps. The round worker does not invoke a
tool module directly.

Add a pure pre-call projector such as `soma_delegate_prompt`. Every projection
has exactly these keys:

```text
objective output_contract task_summary pinned_safety_state recent_rounds
artifact_excerpts tool_schemas
```

`pinned_safety_state` is copied exactly from coordinator-owned state and has
the keys `capability_scope`, `mutation_ledger`, `unknown_outcome_ledger`, and
`idempotency_state`. It is never summarized or truncated. `recent_rounds`
contains only the configured recent window. When a round falls out of that
window, merge its fixed action, status, counts, and observation reference into
one bounded structured `task_summary`. Do not retain its raw observation in
the prompt state.

Render the projection once into the provider messages and estimate tokens from
those exact rendered bytes with one deterministic conservative estimator. The
per-call input allowance is
`max_context_tokens - reserved_completion_tokens`. Fail with
`context_budget_exceeded` before `soma_llm_call:start_owned/1` when the estimate
exceeds that allowance. Apply the same pre-start rule when the estimate plus
committed prompt-token usage would exceed `max_total_prompt_tokens`. Check the
pinned safety state before any optional excerpt reduction. If the safety state
alone does not fit, fail the task without altering it.

Reserve the estimate when a call starts. When a completed provider response
contains a valid prompt-token count, replace that call's estimate in task usage
with the reported count. Extend `soma_llm_openai` response parsing only enough
to retain optional usage metadata. Responses without usage keep their current
shape and use the estimate. Existing actor proposal normalization may continue
to discard the optional metadata.

The coordinator owns the task counters and checks them at the spend point.
Check `max_rounds` before starting another round worker. Check `max_llm_calls`
before the round worker starts another LLM child. Check `max_tool_calls` against
the selected action's step count before starting a run. Counters start at zero
in every new coordinator. A started child consumes its unit even if it later
fails. Each exhaustion becomes terminal failed task data with
`{budget_exceeded, Limit}` and cannot start the prohibited child.

Arm one coordinator-owned absolute task deadline from the normalized budgets.
On expiry, use the existing coordinator-to-worker cancel protocol and wait for
the worker's LLM or run cleanup before publishing terminal `timeout`. A run
continues to own tool-worker and CLI-process teardown. The existing AS.5a
`in_doubt` rule still wins when a non-idempotent dispatched result is lost. The
deadline path must not invent a replay.

Turn every known run completion, tool error, and owner-observed run timeout
into a bounded observation and commit it before starting the next worker.
Record one fresh invocation identity for every model-selected action. A later
selection of the same state tool starts a new run and receives a different
identity. This is an explicit model decision, not an automatic retry. Keep
state invocation outcomes in the mutation and idempotency ledgers. Put an
unresolved unsafe outcome in the unknown-outcome ledger and preserve AS.5a's
terminal `in_doubt` behavior when the result itself is lost.

Add a task-scoped artifact store under `soma_actor_sup` and route access through
the existing `soma_delegate` Erlang boundary. When a serialized observation is
larger than `max_observation_bytes`, store its complete bytes under an opaque
handle bound to the task id. The prompt receives only
`#{handle, bytes, excerpt, truncated}` and the round keeps the same handle as
its observation reference. Delegate events and terminal artifacts reuse that
handle. An artifact slice requires both task id and handle, validates offset
and requested byte count, and returns no more than the requested bytes. It
does not add artifact search or a general index.

Extend `soma_delegate_event` rather than appending delegate events directly.
Keep current lifecycle events and add documented adaptive projections:

- A decision event carries the round, bounded action summary, global-policy
  verdict, and task-capability verdict.
- An action event carries the run id, bounded tool-call id list, and observation
  reference.
- The terminal event carries status plus bounded mutation and unknown-outcome
  state.

The event builder must scrub nested terms before append and keep every event at
or below 4096 deterministic external-term bytes. Its overflow form must retain
the documented keys with bounded summary values. It must never include prompt
text, raw observations, arguments, credentials, pids, ports, references, raw
leases, or provider configuration.

Replace the 512-byte status-only terminal projection with one bounded public
projection containing exactly:

```text
request_id task_id correlation_id status result artifacts mutations
unknown_outcomes usage trace_ref
```

The status vocabulary is `succeeded | failed | rejected | timeout | cancelled
| in_doubt`. `usage` contains the four counters `rounds`, `llm_calls`,
`tool_calls`, and `prompt_tokens`. `trace_ref` is the task correlation id. A
terminal `reply` value that fits the output contract is copied unchanged into
`result`. Large action observations remain artifact-backed and do not inflate
the terminal result. If unresolved unsafe outcomes remain, the terminalizer
must not report `succeeded`.

Put the new process proofs in
`apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`. Keep each issue
criterion in one new case as requested. Use fixed response callbacks and local
test tools only. Update existing AS.5a fixtures to the out-of-request responder
and lease seams without adding replacement acceptance cases. Add
`docs/contracts/AS.5-test-contract.md` and one EUnit source-file pin. The full
gate remains `rebar3 eunit && rebar3 ct` and opens no provider network
connection.

## Acceptance criteria → tests

### Criterion 1 — strict production request boundary

- Call chain: `soma_delegate:submit/1` ->
  `soma_delegate_request:normalize/1` -> request dedupe ->
  `soma_delegate_coordinator_sup:start_coordinator/1`.
- Test entry: `soma_delegate:submit/1`. The table inspects the accepted
  coordinator request for the valid row and counts zero coordinators after
  every forbidden row.
- Code boundary: request normalization in
  `apps/soma_actor/src/soma_delegate_request.erl` and pre-start handling in
  `apps/soma_actor/src/soma_delegate.erl`.
- Responsibility owner: the delegate request normalizer owns the exact
  top-level allowlist, recursive safe-term check, and fixed rejection.
- Test: `test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs`
  in `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 2 — exact task-local prompt fields

- Call chain: delegate submit -> coordinator snapshot ->
  `soma_delegate_prompt:project/2` -> rendered messages -> round worker ->
  `soma_llm_call:start_owned/1` -> fixed responder.
- Test entry: `soma_delegate:submit/1` with a responder installed in the
  test-owned runtime configuration. The responder records every actual
  projection and returns fixed terminal data.
- Code boundary: prompt projection and rendering in
  `apps/soma_actor/src/soma_delegate_prompt.erl` and round startup in
  `soma_delegate_coordinator.erl`.
- Responsibility owner: `soma_delegate_prompt` owns the seven-key model input.
- Test: `test_prompt_projection_uses_exact_task_local_fields` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 3 — ordered admission and state-tool process spine

- Call chain: delegate submit -> fixed model action -> proposal decode ->
  `soma_proposal:normalize/1` -> `soma_policy:check/2` ->
  `soma_delegate_capability:check/2` ->
  `soma_run_sup:start_run/1` -> `soma_run` -> `soma_tool_call`.
- Test entry: `soma_delegate:submit/1`. The case traces the three production
  admission calls in order and observes the run and state-tool worker after an
  allowed proposal.
- Code boundary: reply handling in
  `apps/soma_actor/src/soma_delegate_round_worker.erl` and capability checks in
  `apps/soma_actor/src/soma_delegate_capability.erl`.
- Responsibility owner: the round worker owns ordered action admission. The
  capability module owns task scope. The unchanged runtime owns execution.
- Test: `test_model_action_admission_order_and_state_spine` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 4 — policy, capability, and malformed denials stop before runs

- Call chain: delegate submit -> fixed model action -> normalization -> global
  policy -> task capability -> terminal cleanup. Rejected rows stop at the
  gate that decides them.
- Test entry: `soma_delegate:submit/1` in a table over global-policy denial,
  task-capability denial, and malformed action data. The event store is empty
  of `run.started` for every correlation id.
- Code boundary: the admission result branches in
  `soma_delegate_round_worker.erl` and terminal projection handling in
  `soma_delegate_coordinator.erl`.
- Responsibility owner: normalization owns malformed data. Global policy and
  task capability own their distinct `rejected` verdicts.
- Test: `test_denied_and_malformed_actions_stop_before_run` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 5 — reader, state, then terminal end-to-end sequence

- Call chain: delegate submit -> reader proposal -> reader run -> observation
  commit -> next prompt -> state proposal -> state run -> observation commit ->
  next prompt -> terminal reply -> public projection.
- Test entry: `soma_delegate:submit/1` with a socket-free three-response
  callback that records all prompts.
- Code boundary: round continuation in `soma_delegate_coordinator.erl`, model
  action handling in `soma_delegate_round_worker.erl`, and observation
  projection in `soma_delegate_prompt.erl`.
- Responsibility owner: the coordinator is the only cross-round commit and
  sequencing owner. The round worker owns one decision and action.
- Test: `test_reader_state_terminal_sequence_threads_observations` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 6 — known failures become observations and retries get new identities

- Call chain: model action -> owned run -> known tool error or timeout ->
  bounded observation commit -> next prompt -> later model action for the same
  state tool -> new run and invocation identity.
- Test entry: `soma_delegate:submit/1` with fixed error and timeout rows. Local
  tools make both outcomes deterministic and the responder records the next
  prompt.
- Code boundary: run terminal handling and invocation identity creation in
  `soma_delegate_round_worker.erl`, plus ledger commit in
  `soma_delegate_coordinator.erl`.
- Responsibility owner: the round worker converts known run outcomes to task
  observations. The coordinator owns invocation and safety ledgers.
- Test: `test_failed_and_timed_out_actions_feed_observations_with_fresh_invocations`
  in `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 7 — prompt schemas use the policy and capability intersection

- Call chain: delegate submit -> global policy plus normalized capability
  scope -> `soma_tool_registry:catalog/0` ->
  `soma_delegate_capability:tool_schemas/2` -> prompt projector -> fixed
  responder.
- Test entry: `soma_delegate:submit/1` with catalog tools split across global
  and task allowlists. The responder reads the actual `tool_schemas` field.
- Code boundary: intersection logic in
  `apps/soma_actor/src/soma_delegate_capability.erl` and prompt assembly in
  `soma_delegate_prompt.erl`.
- Responsibility owner: the capability module owns the one intersection used
  for both visibility and execution admission.
- Test: `test_prompt_schemas_equal_policy_capability_intersection` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 8 — round, LLM, and tool budgets stop at their child boundaries

- Call chain: delegate submit -> coordinator round budget check -> round
  worker -> LLM-call budget check -> model proposal -> tool-call budget check ->
  optional run start -> terminal cleanup -> fresh submit.
- Test entry: `soma_delegate:submit/1` in a table over `max_rounds`,
  `max_llm_calls`, and `max_tool_calls`. Supervisor children and events prove
  the prohibited child did not start. A later task exposes zeroed counters.
- Code boundary: counter initialization and pre-start gates in
  `soma_delegate_coordinator.erl` and `soma_delegate_round_worker.erl`.
- Responsibility owner: the coordinator owns task counters. The process that
  starts each child performs that child's final budget check.
- Test: `test_round_llm_and_tool_budgets_stop_before_child_start_and_reset` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 9 — overall deadline tears down the owned execution set

- Call chain: delegate submit -> coordinator task timer -> active round worker
  -> LLM or run -> tool worker -> optional CLI process -> deadline cancel ->
  descendant cleanup -> terminal timeout.
- Test entry: `soma_delegate:submit/1` with local blocked LLM and CLI-action
  rows. The case waits for terminal `timeout` and then checks every discovered
  descendant and OS pid.
- Code boundary: absolute deadline and cleaning transition in
  `soma_delegate_coordinator.erl`, plus existing child teardown in
  `soma_delegate_round_worker.erl`.
- Responsibility owner: the coordinator owns the overall deadline. Each child
  owner must finish its descendants before terminal publication.
- Test: `test_task_deadline_tears_down_all_owned_execution_children` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 10 — context preflight and provider usage replacement

- Call chain: coordinator snapshot -> prompt projection -> token estimate ->
  per-call and total checks -> optional LLM worker -> fixed provider response ->
  reported prompt usage -> coordinator usage commit.
- Test entry: `soma_delegate:submit/1` with three deterministic rows. Two rows
  exceed the per-call or total allowance before worker creation. One completed
  call reports prompt usage different from its estimate.
- Code boundary: estimator and preflight in
  `apps/soma_actor/src/soma_delegate_prompt.erl`, usage commit in
  `soma_delegate_coordinator.erl`, and optional response usage parsing in
  `apps/soma_runtime/src/soma_llm_openai.erl`.
- Responsibility owner: the prompt projector owns pre-call context admission.
  The coordinator owns total accounting. Provider parsing owns reported usage.
- Test: `test_context_preflight_and_provider_usage_accounting` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 11 — oversized observations use one stable task artifact

- Call chain: action run output -> observation serialization -> byte limit ->
  task artifact put -> coordinator commit -> next prompt -> delegate action
  event -> terminal projection -> task-scoped slice.
- Test entry: `soma_delegate:submit/1` with a local reader output above
  `max_observation_bytes`, followed by `soma_delegate:artifact_slice/4` on the
  returned handle.
- Code boundary: observation storage in
  `apps/soma_actor/src/soma_delegate_artifact_store.erl`, prompt excerpts in
  `soma_delegate_prompt.erl`, and artifact routing in `soma_delegate.erl`.
- Responsibility owner: the artifact store owns complete bytes and task-bound
  handles. The projector owns excerpts only.
- Test: `test_oversized_observation_uses_stable_task_artifact_and_bounded_slice`
  in `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 12 — old raw observations collapse into one bounded summary

- Call chain: repeated action completion -> coordinator recent-window update ->
  structured summary merge -> prompt projection -> fixed responder.
- Test entry: `soma_delegate:submit/1` with more fixed actions than the
  configured recent-round window. The last responder inspects the whole
  projection for old raw sentinels and the single summary.
- Code boundary: round-history commit in
  `soma_delegate_coordinator.erl` and summary projection in
  `soma_delegate_prompt.erl`.
- Responsibility owner: the coordinator owns recent history and the one
  bounded summary of evicted rounds.
- Test: `test_recent_round_window_replaces_old_observations_with_one_summary`
  in `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 13 — pinned safety state is exact and never truncated

- Call chain: normalized capability plus coordinator ledgers -> pinned safety
  map -> prompt projector -> context preflight -> optional LLM start.
- Test entry: `soma_delegate:submit/1` with fixed rounds that update mutation,
  unknown-outcome, and idempotency state. A second row makes that state exceed
  the per-call allowance.
- Code boundary: safety-ledger construction in
  `soma_delegate_coordinator.erl` and non-truncating checks in
  `soma_delegate_prompt.erl`.
- Responsibility owner: the coordinator owns authoritative safety state. The
  projector may copy it or reject it, but may not rewrite it.
- Test: `test_pinned_safety_state_is_exact_and_never_truncated` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 14 — cumulative prompts obey the per-call input bound

- Call chain: each round snapshot -> prompt projection -> per-call estimate ->
  usage reservation -> round completion -> next round, repeated N times.
- Test entry: `soma_delegate:submit/1` with N fixed maximum-sized prompt rows
  and no provider usage override. The terminal usage and every captured
  estimate are checked.
- Code boundary: prompt fitting in `soma_delegate_prompt.erl` and cumulative
  accounting in `soma_delegate_coordinator.erl`.
- Responsibility owner: per-call projection plus coordinator accounting owns
  the N-times bound.
- Test: `test_maximum_round_prompts_obey_cumulative_input_bound` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 15 — adaptive events are documented, scrubbed, and bounded

- Call chain: adaptive decision, action completion, or terminal transition ->
  `soma_delegate_event:append/5` -> schema projection -> recursive scrub ->
  4096-byte fit -> `soma_event_store:append/2`.
- Test entry: `soma_delegate:submit/1` in a table over decision, action, and
  terminal transitions with oversized secrets and process-local sentinels.
- Code boundary: event schemas and overflow projections in
  `apps/soma_actor/src/soma_delegate_event.erl`. Producers stay in the
  coordinator and round worker.
- Responsibility owner: `soma_delegate_event` is the only public authority for
  adaptive delegate events.
- Test: `test_adaptive_events_are_documented_scrubbed_and_4096_byte_bounded`
  in `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 16 — terminal projection has the exact public contract

- Call chain: fixed terminal model proposal or terminal fault -> coordinator
  cleanup -> terminal projection builder -> ingress bounded storage ->
  `soma_delegate:status/1`.
- Test entry: `soma_delegate:submit/1` in a table over all six terminal
  statuses. The success row uses a fixed reply matching the output contract.
- Code boundary: terminalization in `soma_delegate_coordinator.erl` and public
  projection storage in `soma_delegate.erl`.
- Responsibility owner: the coordinator owns terminal meaning. The ingress
  stores only the exact bounded public projection.
- Test: `test_terminal_projection_has_exact_public_contract` in
  `apps/soma_actor/test/soma_delegate_adaptive_SUITE.erl`.

### Criterion 17 — AS.5 contract maps every criterion to one hermetic test

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/contracts/AS.5-test-contract.md` because this
  criterion covers the durable guarantee-to-proof map.
- Code boundary: `docs/contracts/AS.5-test-contract.md` and
  `apps/soma_actor/test/soma_as5_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the criterion map. The EUnit
  pin checks one numbered row, one test name, and a zero-network statement for
  every criterion.
- Test: `test_as5_contract_maps_every_criterion_to_one_hermetic_test` in
  `apps/soma_actor/test/soma_as5_contract_doc_tests.erl`.

## Risks & trade-offs

- Moving AS.5a fixtures out of the request will require substantial edits to
  its existing suite. Keeping those responders and lease adapters in trusted
  test configuration is necessary to make the production request boundary
  real. A hidden `round_sequence` compatibility path would defeat criterion 1.
- Conservative byte-based token estimation can reject prompts a provider
  tokenizer would accept. It gives a deterministic pre-call safety check.
  Provider-reported usage corrects completed-call totals but cannot undo a call
  that the estimate already admitted.
- A task artifact store keeps complete observations outside prompt and event
  state. It also creates retained task data after the coordinator exits.
  Retention and index compaction remain separate work, so this slice must keep
  lookup task-scoped and avoid adding search.
- Known tool failures can safely feed a later model decision because the run
  reported a terminal outcome. Loss of a dispatched non-idempotent result is
  different and must stay `in_doubt`. Combining those paths would create an
  accidental retry surface.
- Filtering schemas at prompt time handles live registry changes, but a tool
  can disappear before spend-time admission. The capability gate must resolve
  the live descriptor again and reject without starting a run.
- The exact pinned safety map may consume most or all of a prompt allowance.
  Failing closed preserves mutation and unknown-outcome facts, at the cost of
  ending a task that could have continued after unsafe truncation.
- Adding provider usage metadata must not change responses that omit it or the
  actor planning path. Keep the metadata optional and strip it before proposal
  normalization where needed.
