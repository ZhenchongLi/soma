# RS.1c Test Contract — bounded service reads and terminal cancellation

This document maps every acceptance criterion of the RS.1c service-read slice
(issue #245) to the test case that proves it. The actor-layer service owns the
public status, result, watch, and cancellation contracts; the event store and
runtime retain their existing durable ordering and resource-teardown duties.

## Criterion 1 — terminal status is summary-only and bounded

| Guarantee | Proof |
| --- | --- |
| Successful and failed terminal status reads expose only task identity, lifecycle status, and a deterministic summary whose encoding is at most 512 bytes; result data and internal failure detail remain private. | `soma_service_SUITE:test_terminal_status_has_bounded_summary_only` |

## Criterion 2 — small results stay inline under the configured cap

| Guarantee | Proof |
| --- | --- |
| Results at or below the default or configured inline cap return the complete output through `result/1` without creating an artifact data directory. | `soma_service_SUITE:test_result_inline_uses_default_and_configured_cap` |

## Criterion 3 — an oversized result publishes one stable complete artifact

| Guarantee | Proof |
| --- | --- |
| An oversized result returns a task-scoped descriptor with the exact encoded byte count and bounded prefix, publishes the complete encoded output, and reuses the same artifact without rewriting it on repeated reads. | `soma_service_SUITE:test_oversized_result_publishes_stable_artifact` |

## Criterion 4 — failed publication removes only its owned temporary file

| Guarantee | Proof |
| --- | --- |
| A rename failure after exclusive temporary-file creation removes that owned temporary file while preserving an unrelated file in the artifact directory. | `soma_service_artifact_tests:test_failed_publication_cleans_only_owned_temp` |

## Criterion 5 — missing correlation defaults to task id and watch keeps append order

| Guarantee | Proof |
| --- | --- |
| A task invoked without a correlation id uses its task id for service and run events, and `watch/3` returns that durable correlation trail in append order. | `soma_service_SUITE:test_missing_correlation_defaults_to_task_watch_order` |

## Criterion 6 — opaque cursors resume after the last event and pages are clamped

| Guarantee | Proof |
| --- | --- |
| A watch cursor is opaque, resumes at the event following its exact durable event id, and limits each page by the smaller of the caller limit and configured service cap. | `soma_service_SUITE:test_watch_cursor_resumes_and_page_limit_is_clamped` |

## Criterion 7 — watch recursively removes unsafe terms and oversized payloads

| Guarantee | Proof |
| --- | --- |
| Watch presentation recursively drops secrets, redacts process-local terms and unsafe keys, and replaces oversized payloads with a bounded size marker without changing the stored event. | `soma_service_SUITE:test_watch_recursively_scrubs_secrets_runtime_terms_and_large_payloads` |

## Criterion 8 — cancellation replies after teardown and is idempotent

| Guarantee | Proof |
| --- | --- |
| Public cancellation returns the cancelled terminal projection only after the run, worker, and external process are gone; a repeated cancellation returns the same projection without appending events. | `soma_service_SUITE:test_cancel_is_terminal_and_idempotent_after_teardown` |

## Criterion 9 — result and watch return typed not-found errors

| Guarantee | Proof |
| --- | --- |
| Public result and watch reads for an unknown binary task id both return the fixed `{error, not_found}` response. | `soma_service_SUITE:test_result_and_watch_unknown_task_are_not_found` |

## Criterion 10 — this contract maps every criterion to its proof

| Guarantee | Proof |
| --- | --- |
| This document names one proving module and case for every acceptance criterion of issue #245. | `soma_rs1c_contract_doc_tests:test_rs1c_contract_maps_every_criterion_to_proving_case` |
