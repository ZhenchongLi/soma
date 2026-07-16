# AS.5 Test Contract — bounded adaptive delegation

This document maps every acceptance criterion of the AS.5 adaptive delegation
slice (issue #233) to exactly one hermetic test. The adaptive loop remains above
the unchanged `soma_run -> soma_tool_call` execution spine: one temporary
coordinator owns cross-round state, and one temporary round worker owns each
model decision and optional run.

The AS.5 gate is `rebar3 eunit && rebar3 ct`. Its proofs use fixed response
callbacks, local test tools, in-memory OTP services, and CLI helpers created in
the Common Test private directory. They do not contact a model provider or any
non-local network service.

## Criterion 1 — strict production request boundary

Delegate ingress accepts only the eight documented top-level request fields,
normalizes safe task data before deduplication, and rejects unknown fields or
recursive process, credential, provider, conversation, and lease terms before
minting a task or starting a coordinator.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs`
- Hermetic boundary: A table of fixed Erlang terms and local supervisor-child inspection opens zero provider network connections.

## Criterion 2 — exact task-local prompt fields

Every model projection contains exactly `objective`, `output_contract`,
`task_summary`, `pinned_safety_state`, `recent_rounds`, `artifact_excerpts`, and
`tool_schemas`; trusted responder configuration and forbidden request data do
not enter that projection.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_prompt_projection_uses_exact_task_local_fields`
- Hermetic boundary: A test-owned fixed responder records the actual in-BEAM projection and opens zero provider network connections.

## Criterion 3 — ordered admission and state-tool process spine

A model-selected action passes proposal normalization, the global policy gate,
and the task capability gate in that order before an admitted state step starts
through `soma_run_sup -> soma_run -> soma_tool_call`.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_model_action_admission_order_and_state_spine`
- Hermetic boundary: Local call tracing, a fixed responder, and an in-BEAM state tool expose the real ownership spine with zero provider network connections.

## Criterion 4 — denials stop before runtime execution

Malformed action data terminates as failed, while global-policy and
task-capability denials terminate as rejected at their distinct gates. None of
the three denial classes can emit `run.started`.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_denied_and_malformed_actions_stop_before_run`
- Hermetic boundary: Fixed proposal rows and the in-memory event store prove every pre-run stop with zero provider network connections.

## Criterion 5 — reader, state, then terminal sequence

A completed reader action becomes the next round's observation, a later state
action receives and commits its own observation, and a final model reply becomes
the public terminal result only after both prior rounds have committed.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_reader_state_terminal_sequence_threads_observations`
- Hermetic boundary: One socket-free three-response callback and local tools drive the full sequence with zero provider network connections.

## Criterion 6 — known failures are observations and repeated selections are fresh

Known action failures and owner-observed action timeouts are committed as
bounded observations rather than ending the loop immediately. A later explicit
selection of the same state tool starts a new run with a fresh invocation
identity and updates the safety ledgers without becoming an automatic retry.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_failed_and_timed_out_actions_feed_observations_with_fresh_invocations`
- Hermetic boundary: Deterministic error and timeout tools plus fixed replies exercise only local workers and open zero provider network connections.

## Criterion 7 — prompt schemas equal the policy-capability intersection

The model sees exactly the live catalog entries allowed by both global policy
and task capability, and the same task-capability rule is reused at spend-time
admission so prompt visibility and execution authority cannot drift.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_prompt_schemas_equal_policy_capability_intersection`
- Hermetic boundary: A local registry catalog and a fixed projection-recording responder establish the intersection with zero provider network connections.

## Criterion 8 — round, LLM, and tool budgets stop before prohibited children

The coordinator and round worker check the round, LLM-call, and tool-call limits
at their respective spend points. Exhaustion becomes bounded failed task data,
starts no prohibited child, and does not leak counters into a fresh task.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_round_llm_and_tool_budgets_stop_before_child_start_and_reset`
- Hermetic boundary: Fixed budget rows, supervisor inspection, and local event counts verify each child boundary with zero provider network connections.

## Criterion 9 — the overall deadline tears down the owned execution set

One coordinator-owned absolute deadline cancels an active round and waits for
its LLM or run cleanup, including tool workers and any owned CLI process, before
publishing terminal timeout. It does not replay an unsafe action.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_task_deadline_tears_down_all_owned_execution_children`
- Hermetic boundary: Blocked local callbacks and a CLI helper generated under the test private directory prove descendant teardown with zero provider network connections.

## Criterion 10 — context preflight and provider usage replacement

The exact rendered prompt is conservatively estimated before an LLM child can
start. Per-call and total prompt limits reject oversized work before that child,
while a completed fixed response with valid prompt usage replaces its reserved
estimate in cumulative task accounting.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_context_preflight_and_provider_usage_accounting`
- Hermetic boundary: Deterministic prompt bytes and fixed usage-bearing responses exercise preflight and accounting with zero provider network connections.

## Criterion 11 — oversized observations use one stable task artifact

An observation above `max_observation_bytes` is stored completely under one
opaque task-bound handle. The next prompt, action event, terminal artifact list,
and bounded task-scoped slice all reuse that handle without copying the large
value into public state.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_oversized_observation_uses_stable_task_artifact_and_bounded_slice`
- Hermetic boundary: A local reader and the supervised in-memory artifact store prove handle stability and slicing with zero provider network connections.

## Criterion 12 — old observations collapse into one bounded summary

Only the configured recent-round window retains observation detail. Every
evicted round contributes fixed action, status, count, and observation-reference
fields to one bounded structured task summary, with no old raw sentinel retained
in later prompts.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_recent_round_window_replaces_old_observations_with_one_summary`
- Hermetic boundary: A fixed multi-action response sequence records each local prompt and opens zero provider network connections.

## Criterion 13 — pinned safety state is exact and never truncated

Every prompt copies the task's capability scope, mutation ledger,
unknown-outcome ledger, and idempotency state exactly. If that pinned map alone
exceeds the context allowance, the task fails closed before an LLM starts
instead of summarizing or truncating safety facts.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_pinned_safety_state_is_exact_and_never_truncated`
- Hermetic boundary: Fixed ledger-updating rounds and an undersized local context allowance prove both exact copying and rejection with zero provider network connections.

## Criterion 14 — cumulative prompts obey the per-call input bound

Each of N maximum-sized round projections independently fits the documented
per-call input allowance, and the terminal prompt-token counter equals the sum
of the N conservative estimates when no provider usage override is present.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_maximum_round_prompts_obey_cumulative_input_bound`
- Hermetic boundary: Maximum-sized deterministic prompt fixtures and fixed responses measure only local rendered bytes with zero provider network connections.

## Criterion 15 — adaptive events are documented, scrubbed, and bounded

Adaptive decision, action, and terminal transitions append only through
`soma_delegate_event`. Their documented projections recursively remove secrets
and process-local terms, omit prompt and raw action data, retain required
overflow keys, and remain within 4096 deterministic external-term bytes.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_adaptive_events_are_documented_scrubbed_and_4096_byte_bounded`
- Hermetic boundary: Oversized local sentinels are inspected through the in-memory event store with zero provider network connections.

## Criterion 16 — terminal projection has the exact public contract

Every terminal outcome stores exactly `request_id`, `task_id`,
`correlation_id`, `status`, `result`, `artifacts`, `mutations`,
`unknown_outcomes`, `usage`, and `trace_ref`. The six-status vocabulary, four
usage counters, successful reply value, correlation trace reference, and
unsafe-outcome success guard are preserved in bounded ingress state.

- Hermetic proof: `soma_delegate_adaptive_SUITE:test_terminal_projection_has_exact_public_contract`
- Hermetic boundary: Fixed terminal rows and direct local status reads cover the public projection with zero provider network connections.

## Criterion 17 — this contract maps every criterion to one hermetic test

This file contains exactly one numbered section and one named proving case for
each AS.5 acceptance criterion, and every section explicitly records its
provider-network-free test boundary.

- Hermetic proof: `soma_as5_contract_doc_tests:test_as5_contract_maps_every_criterion_to_one_hermetic_test`
- Hermetic boundary: EUnit reads deterministic repository bytes directly and opens zero provider network connections.
