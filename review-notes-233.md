### Claude

## Verdict

changes-requested

## Real issues

1. The request boundary is still a blacklist, so forbidden task data crosses it. `soma_delegate_request:forbidden_canonical_name/1` misses common credential, conversation-history, and lease namespaces. A production normalization table accepted nested values from all three classes. `soma_delegate:submit/1` treats that `{ok, Request}` as coordinator input. Define the nested task schema or reject those namespaces before returning `{ok, _}`.

2. The action validator is not canonical. `soma_proposal:valid_step/1` checks only the outer map and timeout; it does not validate dependency order or unique step ids. A missing dependency emitted `run.started` and then crashed `soma_run:resolve_args/2`. A duplicate-id two-state-step probe emitted one success and one failure, but `soma_delegate_safety:started_tool_call/2` matched both ledger entries to the first tool call and reported both succeeded. Validate the whole step list before policy admission, and correlate safety facts with an identity that cannot alias.

3. Known tool errors can disappear. `soma_delegate_round_worker:action_observation/2` sends arbitrary tool error terms through `soma_lisp:render/1`, whose map-key renderer accepts only atom and binary keys. A valid error map containing an integer key crashed the round worker. The next prompt had no recent observation or summary, and a later reply made the task succeed. Normalize arbitrary tool outcomes with a total bounded serializer before continuing.

4. Completed-call usage is not task-owned. The round worker keeps provider usage in local state and sends it only with the final round result. A fixed response reported seven prompt tokens and reached `tool.started`; killing the round worker afterward produced terminal usage with the 543-token estimate. Commit authenticated usage at LLM completion, before action execution can lose the worker.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — fail: One table-driven boundary test: the normalized production request contains only `request_id`, `correlation_id`, `objective`, `output_contract`, `capability_scope`, `resource_handles`, `artifacts`, `budgets`, and a request carrying any forbidden input class — product conversation history, provider credentials, raw leases, process terms, `round_sequence` — receives a fixed bounded rejection before coordinator creation. Artifact: `test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs/1` passes, but a production normalization table accepted nested credential, conversation-history, and lease classes that the test does not cover.

- Criterion 2 — pass: Each projected prompt conforms to the task-local fields `objective`, `output_contract`, `task_summary`, `pinned_safety_state`, `recent_rounds`, `artifact_excerpts`, `tool_schemas`. Artifact: `test_prompt_projection_uses_exact_task_local_fields/1` passed in the 19-case adaptive suite and compares the projected prompt field set.

- Criterion 3 — pass: One admission-chain test: every model-selected action passes through `soma_proposal:normalize/1`, then `soma_policy:check/2`, then task capability admission, in that order, and a capability-admitted state action reaches the production `soma_run -> soma_tool_call` spine. Artifact: `test_model_action_admission_order_and_state_spine/1` passed and records the three admission stages before the state-tool event trail.

- Criterion 4 — fail: One table-driven denial test: a policy-denied action and a capability-denied action each produce terminal `rejected` task data, and malformed action data produces terminal `failed` task data — all before any `run.started` event. Artifact: the mapped test passes for its cases, but a production action with a missing `from_step` dependency passed proposal normalization, emitted `run.started`, and then failed in `soma_run:resolve_args/2`.

- Criterion 5 — pass: One end-to-end spine test: a fixed-response production request completes a `reader -> state -> terminal` sequence with a structured result, each completed action observation appears in the immediately following LLM prompt, and the model-selected state-tool action emits exactly one `tool.started` event. Artifact: `test_reader_state_terminal_sequence_threads_observations/1` passed in the targeted adaptive suite.

- Criterion 6 — fail: One failure-observation test: a known tool error and a known tool timeout each appear as bounded observations in the next LLM prompt, and a later model-selected invocation of the same state tool receives a fresh invocation identity in the correlation trail. Artifact: a production known-error probe crashed observation rendering on a valid integer map key; the following prompt contained neither the error observation nor a summary.

- Criterion 7 — pass: Each LLM prompt contains tool schemas from the intersection of global policy with task capability scope. Artifact: `test_prompt_schemas_equal_policy_capability_intersection/1` passed and checks the projected schema set against both gates.

- Criterion 8 — pass: One table-driven budget test: `max_rounds`, `max_llm_calls`, and `max_tool_calls` exhaustion each produce their terminal `{budget_exceeded, _}` data before another round-worker / LLM-worker / run start, and a request after budget exhaustion starts with zero round, LLM-call, tool-call, and prompt-token counters. Artifact: `test_round_llm_and_tool_budgets_stop_before_child_start_and_reset/1` passed for all budget rows and the fresh-request row.

- Criterion 9 — pass: The overall task deadline leaves the task-owned LLM/run/tool/external-process set empty after terminal `timeout`. Artifact: `test_task_deadline_tears_down_all_owned_execution_children/1` passed and checks the owned process set after timeout.

- Criterion 10 — fail: One context-budget test: the pre-call projector rejects an estimated prompt above `max_context_tokens - reserved_completion_tokens` with `context_budget_exceeded` before LLM-worker creation, `max_total_prompt_tokens` exhaustion produces terminal `context_budget_exceeded` data before LLM-worker creation, and provider-reported prompt-token usage replaces the estimate for each completed call in task totals. Artifact: after a production call reported seven prompt tokens and reached `tool.started`, round-worker loss produced terminal usage containing the 543-token estimate instead of the provider count.

- Criterion 11 — pass: One artifact-observation test: an observation above `max_observation_bytes` persists its complete output under an opaque task artifact handle; the next prompt contains only a bounded excerpt, truncation metadata, and the stable handle; the handle stays identical across prompt, audit event, and terminal projection; and a task-local artifact slice returns at most its requested byte count. Artifact: `test_oversized_observation_uses_stable_task_artifact_and_bounded_slice/1` passed and checks the same handle across storage, prompt, event, terminal projection, and bounded retrieval.

- Criterion 12 — pass: A prompt beyond the recent-round window replaces every older raw observation with one bounded structured summary. Artifact: `test_recent_round_window_replaces_old_observations_with_one_summary/1` passed and rejects older raw observations from the projected prompt.

- Criterion 13 — fail: One safety-state test: every projected prompt preserves the exact pinned safety-state map for capability scope, mutation ledger, unknown-outcome ledger, and idempotency state, and pinned safety state above the per-call allowance produces terminal `context_budget_exceeded` data without safety-state truncation. Artifact: a production duplicate-step-id probe recorded one successful and one failed state call, while the pinned mutation ledger marked both calls succeeded after both entries resolved to the first tool-call event.

- Criterion 14 — pass: Across N maximum-sized rounds, cumulative prompt tokens remain at most N times the per-call input allowance. Artifact: `test_maximum_round_prompts_obey_cumulative_input_bound/1` passed with the maximum-sized-round fixture.

- Criterion 15 — fail: One table-driven events test: each adaptive decision, action, and terminal transition appends a scrubbed 4096-byte-bounded event carrying its documented fields (round id + action summary + policy/capability verdicts; run id + tool-call ids + observation reference; status + mutation state + unknown-outcome state). Artifact: the mapped shape-and-size test passes, but the duplicate-step-id production trail wrote an incorrect terminal mutation state: both ledger entries reported success despite one failed tool call.

- Criterion 16 — pass: One terminal-projection test: the public terminal status belongs to `succeeded | failed | rejected | timeout | cancelled | in_doubt`, every terminal projection matches the public fields `request_id`, `task_id`, `correlation_id`, `status`, `result`, `artifacts`, `mutations`, `unknown_outcomes`, `usage`, `trace_ref`, and a fixed terminal response matching `output_contract` appears unchanged under the public `result` field. Artifact: `test_terminal_projection_has_exact_public_contract/1` passed for the status domain, exact key set, and unchanged structured result.

- Criterion 17 — pass: The AS.5 contract document maps every criterion to one hermetic test with zero provider network connections. Artifact: `soma_as5_contract_doc_tests:test_as5_contract_maps_every_criterion_to_one_hermetic_test/0` passed; the full gate completed with 426 EUnit tests and 557 Common Test cases green.
