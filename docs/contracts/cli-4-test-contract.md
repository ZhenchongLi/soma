# CLI.4 Test Contract — detached task ownership, cancellation, and restart recovery

This document maps the detached CLI task guarantees to the tests that prove
them.  Issue #256 extends the original in-daemon CLI.4 lifecycle with durable
ownership: an interrupted detached `soma run` can be recovered only after the
daemon has restored configured tools, and the recovered task remains reachable
through its original task and correlation ids.

## Ownership model

`soma_cli_task_registry` owns detached runs. A new detached run uses a durable
three-record admission handshake: `run.started` first records the fixed internal
`run_origin = cli_detached`, its `task_id`, `auto_resume = false`, and
`admission_required = true` plus a random binary `admission_id`; the registry
then records exactly one `cli.task.accepted` event for the same
run/task/session/correlation/admission identity. After that append is
acknowledged, the paused run records `run.admission.committed` with the same
`admission_id` before crossing its first step/tool boundary. Recovery requires
both proofs. A missing proof is synchronously fenced by the exact
`cli.task.admission_rejected` tombstone, which permanently outranks a late
acceptance or commit. Runtime boot
recognizes only fixed ownership classes and resumes only the exact generic
`runtime_default/true` pair; it imports no actor module, preserving the one-way
`soma_actor -> soma_runtime` dependency.

On boot, generic runtime auto-resume skips the run.  The daemon loads configured
tools and then starts the CLI registry.  One chronological pass over the event
trail builds a bounded projection of marked non-terminal candidates; canonical
resume planning may then query each candidate's run trail.  For each candidate
the registry either adopts an already-live run or invokes the existing resume
executor with itself as owner. Legacy and foreground journals carry no marker
and are never guessed into detached ownership.

Every new `tool.started` also journals the bounded `effect`/`idempotent` safety
snapshot used for that invocation. An in-flight retry requires both that
original snapshot and the currently registered descriptor to be safe. Every
legacy in-flight event without a snapshot fails closed: a historical name alone
cannot prove which descriptor actually ran.

The public active state remains `running`; `run.resumed` is an event describing
the new execution attempt, not a new task lifecycle state.

Cancellation is an owner decision as well as a process message. Before a live
detached cancel or controlled stop is acknowledged, the registry synchronously
records `cli.task.cancel_requested` with the task/run/correlation ids. If the VM
exits before the run can emit `run.cancelled`, recovery adopts and cancels an
existing live run, or—after proving no live owner exists—appends the terminal
directly without starting a resumed run. An ambiguous run/supervisor lookup is
always retried. If the intent cannot be confirmed in the event store, `stop`
returns `stop-failed`, leaves the listener up, and the thin cancel client exits
non-zero.

Cancel intent identity is exact: an existing marker counts only when its
run/task/session/correlation tuple matches the durable owner. A same-RunId
marker for another task cannot authorize cancellation or suppress a required
append. Controlled stop also closes detached admission atomically inside the
registry before taking the cancellation snapshot. Starts serialized earlier
are included; starts serialized later are rejected. Listener pids are admission
generations, so a rebound daemon can open a fresh generation without allowing
an already-accepted handler from the stopped listener to cross the boundary.
Admission and stop calls also carry a bounded authority window. A call that has
timed out at its caller is discarded when it is eventually dequeued; it cannot
start a run or close admission later. Rebinding an existing registry replaces
its configured-tools directory, so a subsequent tool-registry generation is
restored from the latest listener configuration rather than a stopped daemon's
directory. An expired admission-open message is equally authority-free: it
cannot link the registry to its now-dead listener pid or replace the current
generation's configured-tools directory when dequeued later.

An admission call whose durable acceptance or run-side activation outcome is
unknown never renders the normal `(accepted ...)` response. It returns a
structured `admission_in_doubt` error carrying the minted `task_id`, `run_id`,
and `correlation_id`, so the caller retains a stable handle for status/cancel
instead of receiving an uncorrelatable transport failure.

## Proving suites and modules

- `soma_cli_task_registry_tests` proves the in-memory owner survives the
  submitting process and receives normal terminal updates.
- `soma_cli_server_SUITE` proves detached acceptance, status, cancellation,
  worker teardown, repeated terminal cancellation, and foreground behavior over
  the real local socket.
- `soma_cli_SUITE` proves the thin client emits detached/cancel requests and
  returns the daemon reply.
- `soma_cli_resume_SUITE` proves the issue #256 durable restart path, including
  configured CLI tools and their external OS processes.
- `soma_cli_9_stop_SUITE` proves live stop cancellation and worker teardown.
- `soma_cli_md_read_tests` pins the user-facing detached/cancel documentation.
- `soma_cli_4_contract_tests` pins this proof map.

## Proofs to cases

| Guarantee | Suite / module | Case |
| --- | --- | --- |
| A task registered by a short-lived submitter remains registry-owned. | `soma_cli_task_registry_tests` | `test_registered_task_survives_registering_process_exit` |
| A registry-owned run terminal message updates the live projection from `running` to `completed`. | `soma_cli_task_registry_tests` | `test_detached_run_completion_updates_registry_status` |
| A detached run moves from `running` to `completed` after its real socket client disconnects. | `soma_cli_server_SUITE` | `test_detached_run_completes_after_client_close_registry_completed` |
| Legacy `register/2` entries without a durable run journal retain live-pid `cancel`/`cancel_all` compatibility. | `soma_cli_task_registry_tests` | `test_legacy_registered_task_cancel_remains_compatible` |
| A detached request returns an accepted task handle before terminal completion. | `soma_cli_server_SUITE` | `test_detached_run_replies_accepted_before_sleep_terminal` |
| Status reads `running` for a live detached task and a completed terminal after it finishes. | `soma_cli_server_SUITE` | `test_status_running_detached_task_reads_registry`, `test_status_completed_detached_task_reads_completed` |
| Cancel reaches the owned run, records `run.cancelled`, kills its worker, and returns `cancelled`. | `soma_cli_server_SUITE` | `test_cancel_detached_run_records_run_cancelled`, `test_cancel_detached_run_kills_tool_worker`, `test_cancel_detached_run_replies_cancelled` |
| Repeated cancellation of a terminal task starts no work. | `soma_cli_server_SUITE` | `test_cancel_terminal_task_reports_already_terminal_no_new_run` |
| Foreground run ownership and disconnect cancellation remain unchanged. | `soma_cli_server_SUITE` | `test_non_detached_run_still_terminal_and_disconnect_cancels` |
| The client sends detached run and cancel forms over the real socket; an unconfirmed cancel reply exits non-zero. | `soma_cli_SUITE` | `test_run_task_file_detach_returns_accepted`, `test_cancel_sends_cancel_request_prints_reply_exit_zero`, `test_cancel_error_reply_exits_nonzero` |
| New detached journals carry `task_id`, `run_origin = cli_detached`, `auto_resume = false`, `admission_required = true`, a random binary `admission_id`, and restart-safe task ids; exactly one identity-bound `cli.task.accepted` and `run.admission.committed` pair precedes every step/tool boundary, no rejection exists on the happy path, and the invocation carries its bounded repeat-safety snapshot. | `soma_cli_resume_SUITE` | `test_detached_run_journals_durable_cli_owner` |
| If a fresh paused run persists `run.started` but its run and owner die before the queued acceptance append lands, that exact old-owner `cli.task.accepted` marker cannot regain authority when it arrives later: replacement recovery writes one durable `cli.task.admission_rejected` tombstone and reaches cancellation without a commit, resume, step, tool effect, or live claim. | `soma_cli_resume_SUITE` | `test_uncommitted_fresh_admission_fails_closed_after_registry_restart` |
| Rejection is monotonic in either event order: after a replacement durably rejects and cancels a prepared admission, exact old-owner acceptance and commit markers landing later cannot create work; a further registry rebuild still projects cancelled. | `soma_cli_resume_SUITE` | `test_rejected_admission_outvotes_later_exact_acceptance` |
| An exact run-side commit recorded before its edge acceptance is malformed causal order; the later acceptance cannot fill the gap, and replacement recovery rejects/cancels it without work. | `soma_cli_resume_SUITE` | `test_committed_before_accepted_is_rejected` |
| Admission-in-doubt Lisp rendering preserves task/run/correlation ids and is distinct from the normal accepted form. | `soma_cli_task_registry_tests` | `test_structured_admission_in_doubt_render_preserves_ids` |
| Runtime boot defers a detached run; registry startup restores it as `running`, cancel kills the resumed worker, trace preserves one id chain, repeated cancel is a no-op, and the listener serves a later task. | `soma_cli_resume_SUITE` | `test_restarted_detached_run_is_visible_cancellable_and_traceable` |
| An interrupted non-idempotent state step is not executed again and reports the sticky `resume_unsafe` failure through CLI status. | `soma_cli_resume_SUITE` | `test_unsafe_detached_resume_reports_failed_without_reexecution` |
| An unmarked foreground or legacy trail is not adopted as a detached task. | `soma_cli_resume_SUITE` | `test_unmarked_foreground_run_is_not_adopted` |
| A config-registered CLI tool is restored before resume; cancel kills the recovered BEAM worker and external OS process. | `soma_cli_resume_SUITE` | `test_config_cli_tool_recovers_after_restart_and_cancel_kills_os_process` |
| Restarting the listener/registry while runtime stays alive adopts the same run pid and starts no duplicate resumed attempt. | `soma_cli_resume_SUITE` | `test_listener_restart_adopts_live_detached_run_without_second_resume` |
| Restarting only `soma_runtime` while the listener/registry remains alive re-plans the interrupted run under the existing registry and preserves status/cancel. | `soma_cli_resume_SUITE` | `test_runtime_restart_recovers_with_registry_alive` |
| Restarting only the tool registry causes configured descriptors to reload into that exact generation before detached recovery continues. | `soma_cli_resume_SUITE` | `test_tool_registry_generation_reload_recovers_config_tool` |
| A live but unresponsive run makes registry recovery defer within a bound; it starts no duplicate attempt and is adopted once responsive. | `soma_cli_resume_SUITE` | `test_unresponsive_live_run_defers_without_duplicate` |
| A suspended run supervisor keeps registry startup and lookup bounded; recovery remains pending and later adopts the same run. | `soma_cli_resume_SUITE` | `test_suspended_run_supervisor_keeps_recovery_bounded` |
| A timed-out but committed supervisor start is represented by one barrier probe; after the supervisor responds, the same paused child is adopted and activated once. | `soma_cli_resume_SUITE` | `test_start_in_doubt_resumes_once_after_supervisor_unblocks` |
| A durable cancel accepted while start is in doubt fences the paused child before `run.resumed` or its first tool invocation. | `soma_cli_resume_SUITE` | `test_cancel_fences_start_in_doubt_before_first_tool` |
| If the registry that durably cancelled a start-in-doubt run dies, its replacement waits for the old supervisor start barrier; after the supervisor responds the task reaches one cancelled terminal with no live claim, resume, or tool invocation. | `soma_cli_resume_SUITE` | `test_cancelled_start_in_doubt_survives_registry_replacement` |
| While the authoritative store scan is unavailable, status reports recovering and cancel/stop fail closed; recovery continues when the store returns. | `soma_cli_resume_SUITE` | `test_store_unavailable_during_registry_scan_fails_closed` |
| A same-RunId cancel marker with mismatched owner identity is ignored, and a real cancel appends the correctly-bound intent. | `soma_cli_resume_SUITE` | `test_mismatched_cancel_marker_is_not_owner_intent` |
| An unrelated unresponsive run cannot hide an exact responsive detached run during bounded adoption. | `soma_cli_resume_SUITE` | `test_unrelated_unresponsive_run_does_not_block_adoption` |
| Editing an originally state/non-idempotent manifest to reader/idempotent after interruption cannot authorize replay. | `soma_cli_resume_SUITE` | `test_changed_manifest_cannot_weaken_in_flight_resume_safety` |
| A malformed marked resume journal fails closed to one durable failed terminal without crashing daemon startup. | `soma_cli_resume_SUITE` | `test_malformed_marked_journal_fails_closed_without_daemon_crash` |
| A stop acknowledgement durably precedes teardown; an immediate owner/runtime restart finalizes one cancellation and emits no resumed/tool replay. | `soma_cli_resume_SUITE` | `test_stop_cancel_intent_survives_immediate_restart_without_replay` |
| If the event store cannot confirm cancellation intent, stop returns `stop-failed` and keeps the listener alive; it can stop cleanly after the store recovers. | `soma_cli_resume_SUITE` | `test_stop_fails_closed_when_cancel_intent_store_unavailable` |
| Stop atomically quiesces admission with its cancellation snapshot; a detached request already accepted on another connection but queued after stop is rejected. | `soma_cli_resume_SUITE` | `test_stop_quiesce_rejects_concurrent_detached_admission` |
| A stop call that times out while the registry is suspended cannot close admission later when its stale mailbox entry is dequeued; the same listener can still start and cancel detached work. | `soma_cli_resume_SUITE` | `test_timed_out_stop_cannot_close_admission_later` |
| An admission-open call from a short-lived listener that times out while the registry is suspended cannot later link to the dead listener or replace the current owner/tools directory; pre-deadline raw open/stop/start mailbox forms also fail closed, and the current listener generation remains able to admit work. | `soma_cli_resume_SUITE` | `test_timed_out_open_admission_cannot_rebind_dead_owner` |
| A live rebind removes the old listener's link and monitor ownership; an abnormal old-listener death afterward leaves the same registry and new generation alive and able to admit a fully committed detached run. | `soma_cli_resume_SUITE` | `test_live_rebind_ignores_old_owner_down` |
| A detached-start call that times out while the registry is suspended leaves no task projection, durable journal, tool effect, or live RunId claim when its stale mailbox entry is dequeued. | `soma_cli_resume_SUITE` | `test_timed_out_detached_start_has_no_late_effect` |
| A fresh detached run blocked while preparing `run.started` is killed and releases its RunId claim before the bounded request reports `preparation_unresponsive`, even while the event store remains suspended; when the already-queued journal lands later, recovery durably rejects and cancels it without acceptance, run-side commit, step, tool, or file effect. | `soma_cli_resume_SUITE` | `test_timed_out_prepare_retires_claim_and_rejects_late_journal` |
| A finite detached start that times out inside a suspended run supervisor leaves its queued child behind an expired paused-start lease; after the supervisor resumes there is no journal, tool invocation, task projection, or live RunId claim. | `soma_cli_resume_SUITE` | `test_timed_out_supervisor_start_leaves_no_claim_or_effect` |
| Normal controlled stop retires the listener-owned registry and its blocked helper workers; the replacement listener rebuilds the projection with its configured-tools directory, and after the tool registry restarts reload and execution use that new directory. | `soma_cli_resume_SUITE` | `test_rebound_tools_dir_is_used_after_tool_registry_restart`, `test_controlled_stop_retires_blocked_registry_workers` |
| A fully committed trail missing only `run.completed` projects completed across registry rebuilds without replay or extra events. | `soma_cli_resume_SUITE` | `test_nothing_to_do_projection_survives_registry_restart` |
| Recorded completed/failed/timeout/cancelled terminals remain monotonic after restart and repeated cancel is event-free. | `soma_cli_resume_SUITE` | `test_recorded_terminals_remain_monotonic_after_restart` |
| Controlled stop cancels an active detached run and kills its tool worker. | `soma_cli_9_stop_SUITE` | `test_stop_cancels_active_detached_run`, `test_stop_kills_active_detached_tool_worker` |
| User documentation describes detached status/cancel and restart behavior. | `soma_cli_md_read_tests` | `test_cli_md_documents_status_trace_and_defers_cancel_detach`, `test_cli_md_documents_detached_restart_recovery` |
| This contract names every issue #256 proof. | `soma_cli_4_contract_tests` | `test_contract_names_detached_restart_proofs` |

## Explicit boundaries

- Controlled `soma stop` records cancellation intent before reporting stopped,
  so a crash immediately after its reply cannot turn operator-cancelled work
  into a resumed attempt. If that intent cannot be confirmed, stop fails closed
  and does not close the listener.
- Journals created before issue #256 have no durable detached marker and are
  ignored by the CLI registry rather than guessed from textual id prefixes.
  Runtime boot also fails closed for these ownership-ambiguous journals: only
  the new exact `run_origin = runtime_default` plus `auto_resume = true` pair
  opts a generic run into boot replay. This intentionally leaves interrupted
  legacy generic runs for explicit operator recovery after an upgrade.
- Detached `soma ask`, distributed ownership, log compaction, and per-tool
  compensation remain outside this contract.
