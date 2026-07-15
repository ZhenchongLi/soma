# RS.1b Test Contract — runtime service ownership and recovery

This document maps every acceptance criterion of the RS.1b runtime-service
slice (issue #244) to the test case that proves it. The service owns request
deduplication, admission, task lifecycle, deadlines, cancellation, and recovery;
the existing runtime continues to own sequential tool execution and resource
teardown.

## Criterion 1 — the supervised service restarts and serves again

| Guarantee | Proof |
| --- | --- |
| The permanent actor-layer service monitors its owned run, is restarted after a crash, and accepts successful work through the replacement process. | `soma_service_SUITE:test_supervised_service_restarts_and_serves_again` |

## Criterion 2 — one tool succeeds through the production path without an LLM worker

| Guarantee | Proof |
| --- | --- |
| A canonical tool invocation crosses the service, run, and tool-worker boundaries, produces the exact output map and runtime trail, and starts no LLM worker. | `soma_service_SUITE:test_single_tool_invocation_runs_without_llm_worker` |

## Criterion 3 — an oversized task result fails with a typed reason

| Guarantee | Proof |
| --- | --- |
| A result above `max_output_bytes` becomes a bounded failed task with `max_output_bytes_exceeded` and no retained result field. | `soma_service_SUITE:test_oversized_result_fails_with_max_output_reason` |

## Criterion 4 — flat plans preserve source order and from_step data

| Guarantee | Proof |
| --- | --- |
| The service passes canonical steps unchanged so the runtime starts them in source order and resolves the later step from the earlier committed output. | `soma_service_SUITE:test_flat_plan_preserves_order_and_from_step_output` |

## Criterion 5 — identical active and terminal duplicates reuse one task

| Guarantee | Proof |
| --- | --- |
| Repeating an identical envelope while active returns the immutable accepted handle, repeating it after completion returns the stored terminal map, and only one run starts. | `soma_service_SUITE:test_identical_duplicate_reuses_running_handle_and_terminal_result` |

## Criterion 6 — a conflicting request id is rejected before another run starts

| Guarantee | Proof |
| --- | --- |
| Reusing a request id with a different normalized-envelope digest returns `request_id_conflict` without starting another run. | `soma_service_SUITE:test_conflicting_request_id_rejected_before_new_run` |

## Criterion 7 — run.started journals request identity and the envelope hash

| Guarantee | Proof |
| --- | --- |
| The durable `run.started` options preserve the service task id, request id, deterministic SHA-256 envelope hash, budgets, and service-owned resume marker across store replay. | `soma_service_SUITE:test_run_started_journals_request_id_and_envelope_hash` |

## Criterion 8 — durable restart rebuilds dedupe without another run.started

| Guarantee | Proof |
| --- | --- |
| Service restart adopts a matching live run, durable replay reconstructs its terminal result, and an identical request never emits a second `run.started`. | `soma_service_SUITE:test_durable_restart_rebuilds_dedupe_without_new_run_started` |

## Criterion 9 — out-of-scope work is rejected through soma_policy

| Guarantee | Proof |
| --- | --- |
| Binary scope is projected onto registered tool names and the existing policy authority rejects a step outside that projected allowlist without starting a run. | `soma_service_SUITE:test_out_of_scope_invocation_rejected_through_policy` |

## Criterion 10 — unscoped work uses configured policy and fails closed by default

| Guarantee | Proof |
| --- | --- |
| An unscoped invocation uses the configured service policy when present and the empty default policy rejects it without starting a run. | `soma_service_SUITE:test_unscoped_invocation_uses_configured_or_empty_default_policy` |

## Criterion 11 — unknown scope entries create no atom

| Guarantee | Proof |
| --- | --- |
| An unknown external scope binary is rejected through known-name comparison without increasing the VM atom count. | `soma_service_SUITE:test_unknown_scope_entry_does_not_create_atom` |

## Criterion 12 — deadline expiry fails the task and tears down CLI resources

| Guarantee | Proof |
| --- | --- |
| The service deadline cancels the active run, waits for BEAM-worker and external-process teardown, removes the run child, and then exposes `deadline_exceeded`. | `soma_service_SUITE:test_deadline_exceeded_cleans_run_worker_and_cli_process` |

## Criterion 13 — public cancellation reaches cancelled and tears down CLI resources

| Guarantee | Proof |
| --- | --- |
| Public cancellation reaches the run owner, tears down the tool worker and external process, removes the run child, and only then exposes `cancelled`. | `soma_service_SUITE:test_service_cancel_cleans_tool_worker_and_cli_process` |

## Criterion 14 — a tool crash is bounded task data and the service stays usable

| Guarantee | Proof |
| --- | --- |
| A crashing tool becomes a bounded failed task without a raw stack, and the same service process subsequently completes another invocation. | `soma_service_SUITE:test_tool_crash_is_bounded_and_service_runs_again` |

## Criterion 15 — lifecycle reads never regress

| Guarantee | Proof |
| --- | --- |
| The immutable accepted handle, running status, and repeated terminal reads demonstrate a forward-only task lifecycle whose terminal state does not change. | `soma_service_SUITE:test_lifecycle_reads_are_monotonic` |

## Criterion 16 — interrupted unsafe state work recovers as in_doubt

| Guarantee | Proof |
| --- | --- |
| Durable recovery classifies an interrupted non-idempotent state step as `in_doubt` without starting a replacement, resuming the run, or synthesizing `run.failed`. | `soma_service_SUITE:test_unsafe_interrupted_state_invocation_recovers_in_doubt` |

## Criterion 17 — interrupted reader work resumes from the durable trail

| Guarantee | Proof |
| --- | --- |
| Durable recovery resumes an interrupted reader under the original run id, emits one `run.resumed` and no second `run.started`, and reaches service success. | `soma_service_SUITE:test_interrupted_reader_invocation_resumes_after_restart` |

## Criterion 18 — recovery shares descriptor safety and keeps dependencies one-way

| Guarantee | Proof |
| --- | --- |
| Service recovery consumes the runtime-owned descriptor safety rule through the resume plan while runtime source and application dependencies remain actor-free. | `soma_service_boundary_tests:test_recovery_uses_shared_descriptor_safety_without_reverse_dependency` |

## Criterion 19 — this contract maps every criterion to its proof

| Guarantee | Proof |
| --- | --- |
| This document names one proving module and case for every acceptance criterion of issue #244. | `soma_rs1b_contract_doc_tests:test_rs1b_contract_maps_every_criterion_to_proving_case` |
