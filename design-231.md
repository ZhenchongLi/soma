# [cc] agent-shell AS.3: optional bounded reader-only exploration loop

## Current state

AS.1 added the built-in reader tools and live descriptor effects. AS.2 added a
compile-only `soma_lfe:compile/2` path from `(explore ...)` source to
`#{kind => explore, steps => Steps}`. `soma_lisp:render/1` can render that map
back to the same form. Neither slice starts work from an explore map.

`soma_actor` still has one LLM round per task. `maybe_start_llm_call/4` builds
one worker request, checks `max_llm_calls`, and starts a monitored
`soma_llm_call`. A successful result enters the large handler at
`idle(info, {llm_result, ...}, Data)`. Planning mode unwraps provider reply text
only when the task carries `plan => true`. That text then enters
`soma_lfe:compile/2`, `soma_proposal:normalize/1`, the name policy, the step
budget, and proposal execution. An `(explore ...)` result is not a proposal, so
the normalizer rejects it as an unknown kind. A model configuration carrying
`explore => true` has no effect today.

The planning request builder already has the catalog behavior AS.3 needs.
`build_call_opts/2` reads `soma_tool_registry:catalog/0` on each planning call.
`planning_system_prompt/2` filters catalog entries against the actor's
`allowed_tools` policy and renders each surviving entry with
`catalog_blocks/1`. An `all` policy renders the full catalog. There is no
round-aware prompt and no conversation transcript for a second provider call.

Actor-owned runs already have the required OTP shape. `start_owned_run/4`
starts `soma_run` under `soma_run_sup` with `session_pid => self()`. The run
resolves each tool descriptor and starts a distinct `soma_tool_call` worker.
The actor monitors the run and receives `run_completed`, `run_failed`,
`run_timeout`, or `run_cancelled`. All four handlers currently treat that
message as the task's terminal outcome. The `runs` map records only
`RunId => TaskId`, so it cannot distinguish an explore run from the final run.

The task map also keeps old `run_pid` and `llm_call_pid` fields after a child
finishes. That is harmless for a one-child task because the task becomes
terminal. It is unsafe for a multi-round task. A later cancel could select an
old run pid instead of the currently active LLM worker. The monitor map has the
same one-child assumption because it maps a reference to only a task id.

The existing budget record holds `max_llm_calls` and `max_steps` in the actor's
`budget` option. The LLM-call count increments only after a worker starts.
There is no exploration-round count, observation limit, or default for either.
The OpenAI-compatible fixed `response` seam is socket-free, but one fixed
response cannot drive a reader reply followed by a different terminal reply.

Actor events are normalized by `soma_event_store`, which adds the eight
mandatory keys. `soma_trace:render/2` prints event type, task id, step id, and a
reason. It does not print a `round` field. There are no `explore.round.*`
events or `docs/contracts/AS.3-test-contract.md`.

## Approach

Keep the loop in `soma_actor`. Do not add a loop, branch, or new message
protocol to `soma_run`. Every accepted reader action remains one ordinary
sequential run under `soma_run_sup`. Every tool call remains one ordinary
`soma_tool_call` worker.

Enable the new path only when the actor's `model_config` carries
`explore => true`. This mode takes precedence over `plan => true` because the
exploration protocol already accepts terminal proposals. Leave all model
configurations without `explore => true` on the current planning, proposal,
mock, and direct-run paths.

Store the exploration limits in the actor's existing `budget` map, beside
`max_llm_calls` and `max_steps`:

- `max_explore_rounds` defaults to 5.
- `max_observation_bytes` defaults to 16384.

Snapshot those values onto each accepted explore task. Track its next round,
the original envelope, the accumulated assistant-reply and observation
messages, and the active child. One provider reply is one round. For round
`R`, compute `remaining_rounds` as `Max - R + 1`. Use that same value in the
request prompt and both round events. It includes the reply being requested.

Refactor the planning catalog selection into a shared helper that returns the
policy-filtered entries. Planning and exploration prompts must pass that same
list to the existing `catalog_blocks/1` renderer. The explore prompt adds the
protocol around those unchanged blocks. It says that the model must return one
Lisp form. The form may be a reader-only `(explore ...)` action or a terminal
proposal such as `(run-steps ...)`, `(reply ...)`, or `(reject ...)`. It also
states the current round and remaining allowance.

Build each explore request from the custom system prompt, the dynamic explore
system prompt, the original user message, and the transcript in that order.
After a nonterminal reply, append the model text as an assistant message and
append the resulting observation as a user message. Rebuild only the dynamic
system message for the next round. This keeps the current round numbers fresh
while placing the structured observation in the actual second LLM request.

Extend the existing socket-free provider test seam with an ordered
`response_sequence` held in direct `model_config` data. Select one existing
`response` value per task round before starting the worker. Permit a response
entry to be an arity-one test responder that receives the call options and
returns the same `{Status, Body}` shape the fixed seam already parses. This
lets Common Test record the second request, return two fixed provider bodies,
or block or exit on a later round. The key is not loaded from config files and
is not a CLI surface. AS.4 remains the owner of product configuration.

On a successful provider result, take `choices[0].message.content` from the
existing `#{kind => reply, text => Content}` output and compile it once with
`soma_lfe:compile/2`:

- `#{kind := explore, steps := Steps}` is a nonterminal reader action.
- A map accepted by `soma_proposal:normalize/1` is a terminal proposal.
- A parse error or any other compiled shape is an invalid reply.

Do not send invalid exploration replies through the L.5 repair loop. They
become bounded observations and consume the round that produced them. A valid
terminal proposal enters the existing proposal handler. Extract that handler
from the current success clause rather than copying its normalize, event,
policy, budget, and execution branches.

Gate an explore action before starting a run. First apply the actor's current
tool-name policy to the step list. Then resolve every named tool with
`soma_tool_registry:resolve_descriptor/1`. Require `effect => reader` for each
descriptor. Choose the first offending step in source order for the rejection
observation. A descriptor with `identity` or `state` is rejected with its tool
name and declared effect. A missing descriptor or name-policy failure gets a
fixed bounded diagnostic. None of these branches calls `start_owned_run`, so
none can emit `run.started`.

Tag each owned run with a purpose in actor state. Keep the current public
`start_owned_run` behavior for direct steps and terminal `run_steps`. Add an
explore purpose carrying task id, round, remaining allowance, and source steps.
The `runs` map should hold that context instead of a bare task id. Monitor
entries should also identify `llm`, `explore_run`, or `final_run`. Clear the
finished child's pid, reference, timer, and id before starting the next child.
Cancellation then selects one current child instead of testing stale pid keys.

An explore run's four normal terminal messages have loop behavior:

- Completion serializes the step outputs into a completed observation and
  starts the next round.
- Failure serializes a bounded reason/status observation and starts the next
  round.
- Timeout creates a bounded timeout observation and starts the next round.
- Cancellation completes the round as cancelled and terminates the task. It
  does not start another LLM call.

Use source step order when serializing completed outputs. Serialize each output
with `soma_lisp:render/1`. Apply one byte allowance across those serialized
output values. The step ids, observation wrapper, quoting, and marker do not
consume the allowance. Put each retained value inside a quoted field so a
truncated prefix cannot break the outer Lisp form. When the full serialized
outputs exceed the cap, retain at most the cap and append the literal
`(truncated true)` marker outside the counted fields. Record the retained byte
sum as `observation_bytes`. Failure and parse diagnostics use the same maximum
for their dynamic text. Rejection observations use fixed fields such as tool
and effect.

Start a round only after both limits allow it. Check the exploration-round
limit first. Then use the existing `llm_budget_available/2` check. Starting the
worker remains the only place that increments `llm_call_counts`, so every
started round consumes exactly one `max_llm_calls` unit. After the Nth
nonterminal reply, emit that round's completion and fail the task with
`{budget_exceeded, max_explore_rounds}`. Do this before emitting another round
start or calling `start_llm_call`, so no `(N+1)`th `llm.started` event exists.

An LLM worker crash, provider error, or owner timeout is terminal for the
explore task. It is not an observation that starts another round. Complete the
open round with `action => invalid_reply` and the matching failed or timeout
status. Then use the existing task failure/timeout result shape and release an
`ask/3` waiter. On cancel during an LLM round, kill and demonitor the worker,
cancel its timer, complete the round as cancelled, emit the normal task
cancellation data, and release the waiter. On cancel during an explore run,
send `cancel` to the run. The unchanged run kills its tool worker, moves to its
cancelled state, and reports back to the actor.

For a terminal proposal, emit `explore.round.completed` before calling the
shared proposal handler. Use `action => proposal`, `status => completed`, zero
observation bytes, and `truncated => false`. The handler must then produce the
same suffix as planning mode. This preserves `proposal.created`, policy,
`max_steps`, `proposal.executed`, final run ownership, and toolless proposal
results without an explore-only copy.

Emit `explore.round.started` immediately before the round's `llm.started`.
Started events carry task and round identity. Completed events add `action`,
`status`, `observation_bytes`, and `truncated`. Exploration events may add only
these keys beyond the event store's mandatory keys:

```text
actor_id task_id correlation_id round remaining_rounds
action status observation_bytes truncated
```

The only action values are `explore`, `proposal`, and `invalid_reply`. The only
status values are `completed`, `rejected`, `failed`, `timeout`, and `cancelled`.
Use these completed-round pairs:

| Round outcome | `action` | `status` |
| --- | --- | --- |
| Reader run completed | `explore` | `completed` |
| Reader admission rejected | `explore` | `rejected` |
| Reader run failed | `explore` | `failed` |
| Reader run timed out | `explore` | `timeout` |
| Reader run cancelled | `explore` | `cancelled` |
| Terminal proposal parsed | `proposal` | `completed` |
| Invalid model text | `invalid_reply` | `failed` |
| LLM worker or provider failed | `invalid_reply` | `failed` |
| LLM owner timeout | `invalid_reply` | `timeout` |
| LLM worker cancelled | `invalid_reply` | `cancelled` |

Do not put output, diagnostics, pids, monitor references, provider options, or
secrets into the round events. Add `round=N` rendering to
`soma_trace:format_event/1`. The event store's append order then shows each
round before the terminal proposal and run suffix.

Add one actor Common Test suite for the process and loop behavior. Keep prompt
shape checks in the existing `soma_actor_call_opts_tests` EUnit module. Add the
contract pin under `apps/soma_actor/test` and create
`docs/contracts/AS.3-test-contract.md` during the Dev phase.

## Acceptance criteria → tests

### Criterion 1 — `explore => true` treats provider text as a round reply

- Call chain: `soma_actor:send/2` → `idle/3` task acceptance → explore
  round start → `soma_llm_call:start/1` →
  `soma_llm_openai:chat/1` fixed response → `llm_result` → provider text
  extraction → `soma_lfe:compile/2` → explore reply classification.
- Test entry: `soma_actor:send/2` with an OpenAI-compatible fixed response, so
  actor dispatch, worker ownership, provider parsing, and Lisp compilation are
  all exercised.
- Code boundary: explore task initialization and LLM-result routing in
  `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: `soma_actor` owns the optional multi-round mode and the
  provider-text classification boundary.
- Test: `explore_mode_provider_text_is_parsed_as_round_reply` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 2 — explore prompts reuse catalog blocks and state the live round protocol

- Call chain: `soma_actor:send/2` → explore round start → policy tools →
  `build_call_opts/2` → `soma_tool_registry:catalog/0` → shared catalog
  selection → `catalog_blocks/1` → explore system message.
- Test entry: `soma_actor:build_call_opts/2` with the registry fixture. The unit
  test starts at the pure request builder because it must inspect exact system
  message bytes without starting a provider worker.
- Code boundary: request building, shared catalog selection, and prompt
  rendering in `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: the actor request builder owns model-visible policy,
  catalog, protocol, and round text.
- Test: `test_explore_prompt_reuses_policy_filtered_catalog_blocks` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl`.
- Test: `test_explore_prompt_states_protocol_round_and_remaining_allowance` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl`.

### Criterion 3 — accepted reader actions keep the run and tool process boundaries

- Call chain: `soma_actor:send/2` → provider reply →
  `soma_lfe:compile/2` → reader descriptor gate →
  `soma_run_sup:start_run/1` → `soma_run` →
  `soma_tool_registry:resolve_descriptor/1` → `soma_tool_call:start/1`.
- Test entry: `soma_actor:send/2` with a fixed `(explore ...)` provider reply.
  No process layer is bypassed.
- Code boundary: explore admission and purpose-tagged `start_owned_run` calls in
  `apps/soma_actor/src/soma_actor.erl`. `soma_run` and `soma_tool_call` are
  observed but are not modified.
- Responsibility owner: `soma_actor` owns reader admission and run ownership.
  The unchanged runtime owns per-tool process isolation.
- Test: `reader_explore_run_and_tool_worker_are_distinct_children` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 4 — reader observation feeds a second request before the terminal run

- Call chain: `soma_actor:send/2` → fixed response round 1 → reader gate →
  owned explore run → `run_completed` outputs → bounded observation →
  fixed response round 2 request → terminal proposal path → owned final
  run → task result.
- Test entry: `soma_actor:send/2` with a socket-free two-response provider
  sequence whose responder records both request option maps.
- Code boundary: explore transcript, response-sequence selection, observation
  construction, run-purpose dispatch, and terminal handoff in
  `apps/soma_actor/src/soma_actor.erl`, plus the fixed response responder clause
  in `apps/soma_runtime/src/soma_llm_openai.erl`.
- Responsibility owner: `soma_actor` owns the loop spine. The provider seam
  only supplies deterministic responses and exposes the request to the test.
- Test: `reader_then_terminal_run_steps_carries_observation_and_outputs` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 5 — non-reader explore actions are rejected as observations without a run

- Call chain: `soma_actor:send/2` → provider `(explore ...)` text →
  `soma_lfe:compile/2` → policy check →
  `soma_tool_registry:resolve_descriptor/1` → effect rejection → bounded
  observation → next explore round.
- Test entry: `soma_actor:send/2` with a first response naming `file_write` and
  a second terminal reply. This proves rejection and continuation together.
- Code boundary: descriptor admission and rejection observation code in
  `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: the actor exploration gate owns the reader-only rule.
- Test: `non_reader_explore_rejected_with_effect_and_no_run` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 6 — observation output bytes obey the configured and default caps

- Call chain: `soma_actor:send/2` → reader explore run → `run_completed`
  outputs → per-step `soma_lisp:render/1` → byte retention → structured
  observation in the next provider request.
- Test entry: `soma_actor:send/2` with a reader output larger than the chosen
  limit. The response recorder inspects the actual next request and the round
  event metadata.
- Code boundary: observation serialization and limit lookup in
  `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: the actor observation builder owns the prompt-context
  byte ceiling and fixed truncation marker.
- Test: `configured_observation_cap_counts_only_retained_output_bytes` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `default_observation_cap_is_16384_bytes` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 7 — run failures, run timeouts, and invalid replies become next-round observations

- Call chain: `soma_actor:send/2` → round reply → either owned explore run
  terminal message or Lisp classification error → bounded observation →
  next round start with one fewer remaining round.
- Test entry: `soma_actor:send/2` in all three cases. The failure and timeout
  cases run through real `soma_run` terminal messages. The invalid case runs
  through the public Lisp compiler.
- Code boundary: explore run terminal dispatch, invalid-reply classification,
  and continuation in `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: `soma_actor` owns conversion of nonterminal round
  outcomes into the next model observation.
- Test: `failed_explore_run_becomes_next_round_observation` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `timed_out_explore_run_becomes_next_round_observation` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `invalid_round_reply_becomes_bounded_next_observation` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 8 — round and LLM-call budgets stop before an extra worker starts

- Call chain: `soma_actor:send/2` → explore round start → round allowance
  check → existing `llm_budget_available/2` → `start_llm_call/4` →
  `llm_call_counts` increment → nonterminal completion → next allowance
  check or `fail_task/3`.
- Test entry: `soma_actor:send/2` with fixed nonterminal response sequences and
  actor budget maps. Event reads prove how many workers actually started.
- Code boundary: round continuation, default limit lookup,
  `llm_budget_available/2`, and `start_llm_call/4` in
  `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: the actor task budget owns both counters and their
  pre-start gates.
- Test: `configured_round_limit_stops_before_next_llm_start` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `default_round_limit_is_five` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `explore_rounds_consume_existing_llm_call_budget` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 9 — in-loop LLM crash and timeout are terminal task data

- Call chain: `soma_actor:send/2` → first reader observation → second
  `soma_llm_call` → worker monitor `DOWN` or actor-owned timeout → child
  cleanup → round completion → terminal task status and waiter reply.
- Test entry: `soma_actor:send/2` with a socket-free responder that returns the
  first reply, then exits or blocks on the second request.
- Code boundary: LLM monitor, timeout, task failure, and round completion paths
  in `apps/soma_actor/src/soma_actor.erl`. The fixed responder runs behind
  `soma_llm_openai:chat/1`.
- Responsibility owner: the actor owns LLM workers, their timers, and terminal
  task data.
- Test: `in_loop_llm_crash_is_terminal_failed` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `in_loop_llm_timeout_is_terminal_timeout` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 10 — cancellation stops the currently active exploration child

- Call chain: caller → `soma_actor:cancel/2` → active-child lookup →
  either kill and demonitor `soma_llm_call`, or send `cancel` to `soma_run` →
  runtime kills `soma_tool_call` → round and task cancellation data.
- Test entry: `soma_actor:cancel/2` after `soma_actor:send/2` has reached the
  chosen LLM or run phase. No child is killed directly by the test.
- Code boundary: active-child bookkeeping and cancellation in
  `apps/soma_actor/src/soma_actor.erl`. Existing run cancellation in
  `apps/soma_runtime/src/soma_run.erl` is asserted unchanged.
- Responsibility owner: `soma_actor` owns selection and teardown of its active
  child. `soma_run` owns teardown of its tool worker.
- Test: `cancel_during_llm_round_kills_worker_and_cancels_task` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `cancel_during_explore_run_kills_tool_worker_and_cancels_task` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 11 — the actor remains reusable after every exploration terminal failure

- Call chain: first `soma_actor:send/2` → exhaustion, in-loop LLM failure, or
  cancellation → terminal task cleanup → later `soma_actor:send/2` with
  direct steps → owned run → completed task.
- Test entry: both tasks enter through `soma_actor:send/2` on the same actor pid.
- Code boundary: terminal cleanup of tasks, monitors, timers, run contexts, and
  active child fields in `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: the actor state machine owns survival and later task
  acceptance.
- Test: `actor_reusable_after_round_exhaustion` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `actor_reusable_after_in_loop_llm_failure` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `actor_reusable_after_exploration_cancel` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 12 — terminal replies reuse the existing proposal path unchanged

- Call chain: `soma_actor:send/2` → explore provider text →
  `soma_lfe:compile/2` → `soma_proposal:normalize/1` → shared proposal
  handler → `soma_policy:check/2` → optional `max_steps` gate → optional
  `proposal.executed` and owned final run.
- Test entry: `soma_actor:send/2` with one fixed terminal response for each
  proposal outcome. This pins the explore entry path rather than calling the
  proposal helper directly.
- Code boundary: terminal classification and the extracted shared proposal
  handler in `apps/soma_actor/src/soma_actor.erl`.
- Responsibility owner: the existing proposal, policy, budget, and execution
  path remains the sole owner after explore classification.
- Test: `terminal_run_steps_reuses_proposal_execution_suffix` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `terminal_reply_completes_without_run` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `terminal_policy_rejection_starts_no_run` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `terminal_max_steps_failure_starts_no_run` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 13 — round events have the locked schema and traces show ordered rounds

- Call chain: round start or completion → `soma_actor:emit/3` →
  `soma_event_store:append/2` normalization → `by_correlation/2` →
  `soma_trace:render/2` → `format_event/1` with the round field.
- Test entry: `soma_actor:send/2` drives real round events. The test then reads
  the public event store and calls `soma_trace:render/2` on that correlation id.
- Code boundary: round event construction in
  `apps/soma_actor/src/soma_actor.erl` and round formatting in
  `apps/soma_event_store/src/soma_trace.erl`.
- Responsibility owner: `soma_actor` owns event values and field bounds.
  `soma_trace` owns the readable ordered round field.
- Test: `round_events_use_bounded_schema_and_order` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `in_loop_llm_timeout_is_terminal_timeout` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `cancel_during_llm_round_kills_worker_and_cancels_task` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.
- Test: `trace_renders_round_numbers_before_terminal_suffix` in
  `apps/soma_actor/test/soma_actor_explore_SUITE.erl`.

### Criterion 14 — the AS.3 contract maps every guarantee to a named proof

- Call chain: none (direct source-file read).
- Test entry: the EUnit case reads `docs/contracts/AS.3-test-contract.md`
  because the required behavior is documentation coverage.
- Code boundary: `docs/contracts/AS.3-test-contract.md` and
  `apps/soma_actor/test/soma_as3_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the guarantee-to-test map.
- Test: `test_as3_contract_names_every_acceptance_proof` in
  `apps/soma_actor/test/soma_as3_contract_doc_tests.erl`.

## Risks & trade-offs

- Multi-round work makes stale child metadata dangerous. Purpose-tagged run and
  monitor entries add actor-state bookkeeping, but they keep cancellation and
  crash handling tied to the child that is actually active.
- The response sequence and responder function are direct test seams. They add
  production clauses to code that already supports fixed responses, but config
  files and the CLI cannot construct Erlang functions. Keeping the seam out of
  emitted events also avoids exposing request options or API keys.
- The observation cap bounds only context copied back into the model request.
  The unchanged runtime still records full step outputs in `step.succeeded`
  events. Bounding runtime journals would require a `soma_run` contract change
  and is outside this issue.
- A retained output is a quoted string containing canonical Lisp serialization.
  This keeps the outer observation well formed after a byte cut, but the model
  must read one nested serialized value. Cutting at a valid UTF-8 boundary may
  retain fewer than N bytes, which still satisfies the ceiling.
- The prompt shows the same policy-filtered catalog as planning mode, including
  state tools that may be useful in a terminal proposal. The actor gate, not the
  prompt, is the authority that prevents those tools from running in an
  `(explore ...)` action.
- The round cap counts replies, as locked by the issue. One reply may contain
  several sequential reader steps, so `max_explore_rounds` is not a per-step
  ceiling. The runtime's existing per-step timeout still applies.
- Cancelling an explore run preserves the current `soma_run` terminal-state
  model. The run process moves to `cancelled` and its tool worker dies. The
  actor clears it as the active child. Killing the terminal run container would
  be a runtime behavior change and is out of scope.
- Terminal `run_steps` proposals still use the current name allowlist. A reader
  exploration gate does not turn terminal policy into an effect-aware policy.
