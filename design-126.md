## Current state

CLI.3 added `soma status` and `soma trace`, but both are read-side commands over
state that already exists in the event store. `soma_cli_server` still handles a
write request with one process per socket connection: a `(run ...)` request starts
a `soma_run` with `session_pid => self()`, waits in the handler for the terminal
`{run_completed | run_failed | run_timeout | run_cancelled, ...}` message, renders
a terminal `(result ...)`, then closes the socket. If the client disconnects while
the handler is waiting, the handler sends `cancel` to the live run pid and returns
no reply. That is the right behavior for synchronous runs, but it means the run
is owned by the connection handler.

`handle_status/1` currently derives state only from
`soma_event_store:by_session(Store, TaskId)`, relying on the run path aliasing
`session_id` to `task_id`. A running task has no terminal event yet, so it reads
as `unknown`. There is no process outside the handler that owns live task ids,
run pids, or cancellation by id.

The LFE compiler has top-level routes for `run`, `ask`, `trace`, and `status`.
`parse_run/1` accepts only `step` children, so `(detach)` is currently an unknown
run child. There is no `(cancel "...")` top-level form. `soma_cli` exports
`run/1`, `ask/1`, `trace/1`, `status/1`, and `daemon/1`; there is no exported
`cancel/1`, and `run/1` ships workflow bytes unchanged.

The existing runtime cancellation primitive is already sufficient. A live
`soma_run` in `waiting_tool` handles the atom `cancel`, kills the active
`soma_tool_call` worker, kills the external OS process when one was reported,
emits `run.cancelled`, tells its `session_pid`, and reaches the explicit
`cancelled` state. CLI.4 should use that primitive, not add another cancellation
path inside tools or sessions.

## Approach

Add a daemon-owned live-task registry in `apps/soma_actor`, because the CLI server
and client already live there and this layer can depend on both `soma_runtime`
and `soma_lfe` without inverting runtime dependencies.

Introduce `soma_cli_task_registry` as a `gen_server` whose state is at least:

```erlang
#{tasks => #{TaskId => #{pid := Pid,
                         status := running | completed | failed | timeout | cancelled,
                         correlation_id := CorrId,
                         run_id => RunId}},
  runs => #{RunId => TaskId}}
```

The public API should include `register/2`, `lookup/1`, `update_status/2`,
`start_detached_run/5`, and `cancel/1`. `register/2` is kept as a small direct
API so the persistence-of-entry proof can register from a short-lived process.
The registry must not key ownership to the caller that registered an entry; the
entry remains until explicitly updated or the daemon exits.

Start the registry under `soma_actor_sup` as a normal supervised worker, not from
a connection handler. To keep existing actor APIs stable, change
`soma_actor_sup:start_actor/1` to start a temporary dynamic child spec under a
`one_for_one` supervisor while preserving its exported function shape. This is a
supervisor-shape change only; actors and runs still execute as separate OTP
processes, and `soma_agent_session` still never executes tools. `soma_cli:daemon/1`
should ensure the actor/CLI app supervision is up as well as `soma_runtime`, so
the registry exists before the server accepts detached/status/cancel requests.

For detached runs, make the registry the run's owner for terminal notifications.
`soma_cli_task_registry:start_detached_run(TaskId, CorrId, RunId, Steps, Store)`
runs inside the registry process, calls `soma_run_sup:start_run/1` with
`session_pid => self()`, records `TaskId => #{pid => RunPid, status => running,
correlation_id => CorrId, run_id => RunId}`, records `RunId => TaskId`, and then
returns the accepted ids to the handler. Because the state is updated before the
registry processes later mailbox messages, a fast terminal message from the run
cannot arrive at an unmapped `RunId`. On `{run_completed, RunId, _Outputs}`,
`{run_failed, RunId, _Reason}`, `{run_timeout, RunId}`, and
`{run_cancelled, RunId}`, the registry updates the task status to the matching
terminal atom and keeps the entry readable.

For detached `(run ...)` requests, `soma_cli_server` should:

1. Mint `TaskId`, `CorrId`, and `RunId`.
2. Ask the registry to start the detached run.
3. Immediately reply `(accepted (task-id "...") (correlation-id "..."))`.
4. Close the socket without arming the disconnect watcher for that run.

That accepted reply is intentionally not a terminal `(result ...)`. The slow
sleep proof should show that it arrives while the run is still in `running`.

For non-detached `(run ...)` requests, keep the current path: handler-owned run,
terminal `(result ...)`, and cancel-on-disconnect. This preserves the CLI.1b /
CLI.1.5 behavior and proves `--detach` is an opt-in change.

Extend the LFE compiler as follows:

- Route top-level `(cancel "task-id")` to
  `{ok, #{cancel => #{task_id => <<"task-id">>}}}`.
- Accept `(detach)` as a run child marker. With the marker, return
  `{ok, #{run => #{steps => Steps, detach => true}}}`. Without it, return the
  existing unflagged `#{run => #{steps => Steps}}`.
- Also accept `(detach)` in `(ask ...)` as `#{ask => #{..., detach => true}}` so
  `soma ask --detach` can use the same accepted-reply command shape, even though
  the running/cancel acceptance proofs are on the deterministic run path.

For status, check the live registry before falling back to the event store:

```erlang
case soma_cli_task_registry:lookup(TaskId) of
    {ok, #{status := Status}} -> Status;
    {error, not_found} -> derive_state(soma_event_store:by_session(Store, TaskId))
end
```

This makes a running detached task answer `(status (state running))` even though
there is no terminal event yet, while keeping CLI.3 terminal-event behavior for
older synchronous run tasks and unknown ids.

For cancel, add a `handle_cancel/1` branch in `soma_cli_server`:

- If the registry has a live `running` task, call `soma_cli_task_registry:cancel/1`.
  The registry sends `cancel` to the stored pid when the entry is a detached run.
  The handler then waits briefly for the registry to observe the run's terminal
  message and replies with a terminal result, normally
  `(result (status cancelled) (task-id "...") (correlation-id "..."))`.
- If the registry entry is already terminal, reply exactly
  `(result (status <state>) (note already-terminal))` and do not send `cancel`.
- If the registry misses but the event store has a terminal state for that task
  id, return the same `already-terminal` result.
- If neither registry nor event store knows the id, return a defined result such
  as `(result (status unknown) (error not-found))`; unknown cancel is not a run
  start and must not crash the daemon.

The cancel handler should not kill tool workers itself. It only sends `cancel` to
the live `soma_run` pid; `soma_run` remains the component that kills the
`soma_tool_call` worker, tears down any external OS child, and emits
`run.cancelled`.

Add small rendering support for the new command replies. Either hand-render the
fixed `(accepted ...)` and cancel results in `soma_cli_server`, or extend
`soma_lisp:render/1` so result maps with `status` plus `task_id`, `correlation_id`,
or `note` render as `(result ...)`, and accepted maps render as `(accepted ...)`.
Whichever path is chosen, keep the existing terminal result order stable for
completed run/ask replies.

In `soma_cli`:

- Export `cancel/1`; it builds `(cancel "task-id")`, sends it over the same local
  socket framing, prints the reply, and returns an exit code.
- `run/1` with `detach => true` sends a `(run ...)` request carrying `(detach)`.
  The safest implementation is a small request-source helper that parses the
  single top-level `(run ...)` form with `soma_lfe_reader`, prepends the marker,
  and serializes only the supported request form; malformed source still fails in
  the daemon as today.
- `ask/1` with `detach => true` appends `(detach)` to the generated `(ask ...)`
  request. Detached ask should return `(accepted ...)` through the same server
  reply path, but the observable running-state/cancel proofs stay on detached
  `run`, because the current ask path uses a fast mock LLM.
- Detached accepted replies should return exit code `0`; synchronous `run` and
  `ask` keep their existing completed/non-completed exit-code behavior.

Update `docs/cli.md` to remove the CLI.3 deferral language, document
`soma run --detach`, `soma ask --detach`, `(accepted ...)`, registry-backed
`status`, and `soma cancel <task-id>`. Add
`docs/contracts/cli-4-test-contract.md` mapping the proofs below to suites/cases.

## Acceptance criteria → tests

| Criterion | Suite / module | Case |
| --- | --- | --- |
| `(cancel "task-id")` compiles to `{ok, #{cancel => #{task_id => <<"task-id">>}}}` | `soma_lfe_cli_4_tests` | `test_cancel_compiles_to_cancel_command` |
| `(run ... (detach) ...)` compiles with `detach => true` under `run` | `soma_lfe_cli_4_tests` | `test_run_detach_marker_sets_detach_true` |
| `(run ...)` without `(detach)` is not flagged detached | `soma_lfe_cli_4_tests` | `test_run_without_detach_has_no_detach_flag` |
| Registry is owned outside the connection handler; an entry remains after the registering process exits | `soma_cli_task_registry_tests` | `test_registered_task_survives_registering_process_exit` |
| Registered task terminal status updates to `completed` when its run completes | `soma_cli_task_registry_tests` | `test_detached_run_completion_updates_registry_status` |
| Detached slow run replies `(accepted ...)` before terminal state | `soma_cli_server_SUITE` | `test_detached_run_replies_accepted_before_sleep_terminal` |
| After accepted reply and client close, detached run completes in daemon and registry reads `completed` | `soma_cli_server_SUITE` | `test_detached_run_completes_after_client_close_registry_completed` |
| `(status "task-id")` for a running detached task returns `(state running)` from registry | `soma_cli_server_SUITE` | `test_status_running_detached_task_reads_registry` |
| `(status "task-id")` for a completed detached task returns `(state completed)` | `soma_cli_server_SUITE` | `test_status_completed_detached_task_reads_completed` |
| `(cancel "task-id")` for running detached sleep records `run.cancelled` | `soma_cli_server_SUITE` | `test_cancel_detached_run_records_run_cancelled` |
| Cancel of running detached sleep leaves active tool-call worker dead | `soma_cli_server_SUITE` | `test_cancel_detached_run_kills_tool_worker` |
| Cancel reply for running detached task reports cancelled | `soma_cli_server_SUITE` | `test_cancel_detached_run_replies_cancelled` |
| Cancel of already-terminal task replies `(result (status <state>) (note already-terminal))` and starts no new run | `soma_cli_server_SUITE` | `test_cancel_terminal_task_reports_already_terminal_no_new_run` |
| Non-detached run still replies terminal `(result ...)`, never `(accepted ...)`; disconnect mid-run still cancels | `soma_cli_server_SUITE` | `test_non_detached_run_still_terminal_and_disconnect_cancels` |
| `soma_cli:cancel/1` is exported and sends `(cancel "task-id")` over the local socket | `soma_cli_SUITE` | `test_cancel_sends_cancel_request_prints_reply_exit_zero` |
| `soma_cli:run/1` and `soma_cli:ask/1` with a detach flag send requests carrying `(detach)` | `soma_cli_SUITE` | `test_run_detach_sends_detach_marker` and `test_ask_detach_sends_detach_marker` |
| `docs/cli.md` documents `--detach` and `soma cancel <task-id>` and no longer marks them deferred | `soma_cli_md_read_tests` | `test_cli_md_documents_detach_and_cancel_not_deferred` |
| `docs/contracts/cli-4-test-contract.md` exists and maps each proof | `soma_cli_4_contract_tests` | `test_doc_names_cli_4_suites_and_cases` |
| `rebar3 eunit && rebar3 ct` is green; `rebar3 dialyzer` result is reported with no new touched-file warning | build / PR evidence | no runtime test case; record in PR body, and optionally pin a local dialyzer note if the relay flow needs a pre-PR carrier |

## Risks & trade-offs

- Converting `soma_actor_sup` away from `simple_one_for_one` is the main
  structural edit. It is worth doing because the registry is daemon state and
  should be supervised, but the implementation must preserve `start_actor/1` so
  existing actor and CLI tests do not learn the supervisor internals.
- The registry is intentionally in-memory. It is a live-task registry, not
  persistent resume. After daemon restart, terminal history still comes from the
  event store, but live running tasks are gone. That matches the issue scope.
- Status lookup becomes two-source: registry first, event store second. This is
  necessary for `running`, but tests should pin the precedence so a running task
  is not misreported as `unknown` just because no terminal event exists.
- Cancel has a race with natural completion. If a task reaches `completed`
  between lookup and cancel, the honest result is an already-terminal completed
  reply, not a forced cancelled state. The handler should report the terminal
  status the registry observes.
- `soma ask --detach` is included for command symmetry and accepted-reply
  plumbing, but the hard running/cancel proofs should remain on `(run ...)` with
  a slow `sleep` step. The current ask mock can complete too quickly to prove a
  stable running state.
- Request mutation for `soma run --detach` is a small client-side exception to
  the older "client does not parse Lisp" simplification. Keep it constrained to
  inserting the one top-level `(detach)` marker and leave validation/execution to
  the daemon compiler.
