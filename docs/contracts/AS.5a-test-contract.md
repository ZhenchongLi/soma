# AS.5a Test Contract — per-task delegation ownership

This document maps every acceptance criterion of the AS.5a delegation slice
(issue #234) to exactly one hermetic test. Delegated work is owned by one
temporary coordinator per task and one temporary worker per round; the
registered ingress retains only routing and bounded public projections.

The AS.5a gate is `rebar3 eunit && rebar3 ct`. Its delegate cases use fixed LLM
directives and provider responses, test-only lease adapters and tools, and CLI
helpers generated inside the Common Test private directory. No proof opens a
provider or non-local network connection.

Delegate lifecycle events are constructed only by `soma_delegate_event`. Their
maximum deterministic external-term size is 4096 bytes, as returned by
`soma_delegate_event:max_bytes/0`; oversized allowed data falls back to a fixed
bounded summary, and forbidden nested terms are rejected or redacted.

## Compatibility proofs

The delegate layer is additive. The merge gate retains these representative
proofs for the existing public result contracts:

- Runtime service: `soma_service_SUITE:test_single_tool_invocation_runs_without_llm_worker`
- Local CLI: `soma_cli_server_SUITE:test_run_lisp_echo_returns_completed_result`
- Actor: `soma_actor_SUITE:task_result_holds_outputs_after_run`

## Criterion 1 — one request identity owns one coordinator

One bounded request id mints one immutable accepted handle and one monitored
coordinator, and every duplicate submit returns that handle without starting a
replacement.

- Hermetic proof: `soma_delegate_SUITE:test_request_identity_reuses_one_live_coordinator`
- Hermetic boundary: A fixed blocked round exposes the live coordinator without provider, socket, or timing-dependent external work.

## Criterion 2 — coordinator state does not leak into ingress state

Task reasoning state remains in the task coordinator while ingress retains only
request routing, the accepted handle, active ownership metadata, waiters, and a
bounded terminal projection.

- Hermetic proof: `soma_delegate_SUITE:test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections`
- Hermetic boundary: Deterministic in-BEAM barriers permit direct OTP state inspection before and after cleanup.

## Criterion 3 — status and cancellation route by task id

Public status and cancellation find the active coordinator through the task
route, and cancellation replies only after descendant cleanup and terminal
projection storage.

- Hermetic proof: `soma_delegate_SUITE:test_status_and_cancel_route_by_task_id`
- Hermetic boundary: A fixed blocked round supplies a stable cancellation point entirely inside the local BEAM.

## Criterion 4 — coordinator and round-worker crashes do not kill ingress

Temporary coordinator and round-worker failures become bounded task data while
the permanent registered ingress remains responsive to status and later work.

- Hermetic proof: `soma_delegate_SUITE:test_coordinator_and_round_worker_crashes_leave_ingress_responsive`
- Hermetic boundary: The test injects exits only into discovered local child pids and uses fixed replacement work.

## Criterion 5 — production action crosses the full process spine

A delegated action crosses ingress, coordinator, disposable round worker,
owned LLM call, runtime run, and one disposable tool worker per canonical step.

- Hermetic proof: `soma_delegate_SUITE:test_delegate_action_crosses_full_worker_run_tool_spine`
- Hermetic boundary: Fixed LLM data and in-BEAM test tools prove the production ownership path without a provider connection.

## Criterion 6 — coordinator and worker own different child layers

The coordinator owns only its active round worker and overall round bound; the
round worker owns its LLM or run child, monitor, phase timer, and cancel path.

- Hermetic proof: `soma_delegate_SUITE:test_coordinator_and_round_worker_split_child_ownership`
- Hermetic boundary: Fixed phase barriers expose real local links, monitors, timers, and owner records without external services.

## Criterion 7 — sequential rounds commit before a distinct next worker

A valid round result commits once, clears the completed worker and timer, and
only then starts a new worker with the next positive round id and updated
snapshot.

- Hermetic proof: `soma_delegate_SUITE:test_sequential_rounds_commit_before_distinct_next_worker`
- Hermetic boundary: Two fixed round callbacks report their local pids and snapshots through deterministic test messages.

## Criterion 8 — round snapshots are bounded and task-only

Every immutable snapshot is at most 65,536 deterministic external-term bytes,
contains only projected task context, and carries opaque lease handles instead
of raw leases or process-control terms.

- Hermetic proof: `soma_delegate_SUITE:test_round_snapshot_is_bounded_task_only_and_handle_scoped`
- Hermetic boundary: Test-only sentinels, lease adapter, and handle-aware in-BEAM tool record the copied snapshot and handle path.

## Criterion 9 — only the active worker can commit one round result

The coordinator accepts a bounded result only when task, round, worker pid,
worker identity, and capability match the active record; stale, duplicate, and
mismatched messages are no-ops.

- Hermetic proof: `soma_delegate_SUITE:test_round_result_identity_rejects_stale_duplicate_and_mismatched_messages`
- Hermetic boundary: The test sends crafted Erlang messages to one blocked local coordinator and compares its complete state term.

## Criterion 10 — pre-stateful crash and timeout become bounded round failures

A worker loss before unsafe dispatch and an owner-enforced overall round
timeout become bounded failure data without killing the coordinator or silently
retrying the same round.

- Hermetic proof: `soma_delegate_SUITE:test_pre_stateful_worker_crash_and_timeout_are_bounded`
- Hermetic boundary: Fixed crash and blocked-LLM fixtures exercise local monitors and timers without real model traffic.

## Criterion 11 — lost unsafe result reaches in_doubt without replay

After unsafe dispatch, loss of the round worker records one unknown outcome,
terminates the task as `in_doubt`, and starts neither a replacement worker nor
a second tool invocation.

- Hermetic proof: `soma_delegate_SUITE:test_lost_state_result_is_in_doubt_without_replacement`
- Hermetic boundary: A deterministic in-BEAM state tool blocks after its single recorded invocation until the local worker is killed.

## Criterion 12 — task leases stay stable and release exactly once

One lease guard acquires each task lease once, supplies the same opaque handles
to every round, and releases each raw lease once after success, failure,
timeout, cancellation, partial acquisition failure, or coordinator death.

- Hermetic proof: `soma_delegate_SUITE:test_task_leases_are_stable_and_released_once_for_all_outcomes`
- Hermetic boundary: A test-only in-memory lease adapter records every acquisition and release callback by task.

## Criterion 13 — cancellation removes every active child and stops later rounds

Public cancellation tears down an active LLM or run, tool worker, and recorded
CLI process, removes temporary children, emits one cancellation, and prevents a
later round before replying.

- Hermetic proof: `soma_delegate_SUITE:test_cancel_tears_down_llm_run_tool_and_os_children_once`
- Hermetic boundary: Fixed LLM barriers and a CLI helper generated in the Common Test private directory avoid provider and non-local network access.

## Criterion 14 — concurrent tasks keep all mutable state disjoint

Distinct submissions own distinct coordinators, lease guards, round workers,
context, budgets, ledgers, and handles; cancellation of one route does not alter
the other task.

- Hermetic proof: `soma_delegate_SUITE:test_concurrent_tasks_isolate_state_workers_and_leases`
- Hermetic boundary: Two fixed blocked rounds and the in-memory lease adapter make both local task trees observable at once.

## Criterion 15 — one cleanup transition removes all task-local reasoning state

Every expected terminal outcome enters the same guarded cleaning transition,
tears down children, releases leases, publishes one bounded projection, exits
the coordinator, and leaves a fresh request free of prior task sentinels.

- Hermetic proof: `soma_delegate_SUITE:test_terminal_cleanup_scrubs_task_state_before_fresh_request`
- Hermetic boundary: Table-driven fixed outcomes and local process monitors prove heap-lifetime cleanup without persistent or remote dependencies.

## Criterion 16 — public delegate events are stable, bounded, and scrubbed

Every `delegate.*` event uses the allowlisted lifecycle schema, includes task
and correlation ids plus a top-level round, and remains within the 4096-byte
deterministic external-term cap without unsafe nested terms or full results.

- Hermetic proof: `soma_delegate_SUITE:test_delegate_events_are_bounded_stable_and_scrubbed`
- Hermetic boundary: Oversized and forbidden local sentinels are inspected through the in-memory event store and trace renderer.

## Criterion 17 — delegate completion preserves existing public result contracts

Adding delegate completion does not change the established runtime-service,
local-CLI, or direct-actor result shapes.

- Hermetic proof: `soma_delegate_SUITE:test_completed_delegate_preserves_existing_result_contracts`
- Hermetic boundary: Fixed delegate work is followed by in-BEAM echo work and one real local Unix socket; no provider or non-local connection is opened.

## Criterion 18 — AS.5a contract maps every criterion to one hermetic proof

This document contains exactly one numbered section, one named proving case,
and one explicit hermetic-boundary rationale for every acceptance criterion of
issue #234.

- Hermetic proof: `soma_as5a_contract_doc_tests:test_as5a_contract_maps_every_criterion_to_one_hermetic_test`
- Hermetic boundary: EUnit reads this repository file directly and checks only deterministic binary content.
