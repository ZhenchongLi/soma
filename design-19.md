# [cc] v0.2: harden CLI port lifecycle for timeout and cancellation

## Current state

When a run times out or is cancelled, `soma_run` does `exit(WorkerPid, kill)` on
the active `soma_tool_call` worker. See the `step_timeout` and `cancel` clauses
of `waiting_tool/3` in `apps/soma_runtime/src/soma_run.erl` (the two
`exit(WorkerPid, kill)` calls). That removes the BEAM worker process and nothing
else.

For an `erlang_module` tool that is the whole story: the tool ran inside the
worker, so killing the worker stops it. The two existing proofs
(`test_hung_worker_dead_after_timeout`, `test_worker_dead_after_cancel` in
`apps/soma_runtime/test/soma_run_failure_SUITE.erl`) use the `sleep` tool, which
sleeps in-BEAM, so `is_process_alive(WorkerPid) =:= false` is enough.

The `cli` adapter from #18 is different. Look at `run_cli/3` in
`apps/soma_runtime/src/soma_tool_call.erl`: the worker calls
`open_port({spawn_executable, Executable}, ...)` and then sits in `collect_cli/2`
reading from the port. The port spawns a real OS process. When `soma_run` sends
`exit(WorkerPid, kill)`, the worker dies before it can close the port, and the
BEAM closing a port does not reliably reap the OS child that the port spawned. A
hung external program can keep running after the run has already reached
`timeout` or `cancelled` — an orphan, with no process left in the system that
knows about it.

So the v0.1 teardown is BEAM-only. It satisfies the contract for in-BEAM tools
but not for an external OS process. Cancellation is supposed to be real, and for
a `cli` step "real" has to mean the external program is gone, not just the worker
that launched it.

## Approach

Target state: when a run with an active `cli` step reaches `timeout` or
`cancelled`, the external OS process that step launched is dead.

### Who kills the OS process

`exit(WorkerPid, kill)` is an unconditional kill — a `kill`-reason exit cannot be
trapped, so the worker gets no chance to run cleanup before it dies. That rules
out "the worker closes the port and kills its child on the way out". The kill has
to come from someone who outlives the worker, and that is `soma_run`.

So: the worker captures the OS pid of the spawned process and reports it to
`soma_run`; `soma_run` keeps killing the worker as it does today, and in the same
teardown step also kills the captured OS pid.

### Capturing the OS pid

In `run_cli/3`, after `open_port`, read the child's OS pid with
`erlang:port_info(Port, os_pid)`. That returns `{os_pid, OsPid}` for a spawned
executable. The worker sends that pid up to `soma_run` before it blocks in
`collect_cli/2`, so the run holds the OS pid the whole time the step is in flight.

The cleanest carrier is a new message from the worker to its `reply_to` (the run)
the moment the port is open, before any stdout collection — something like
`{tool_started_os_pid, ToolCallId, self(), OsPid}`. `soma_run` records it in
`#data{}` alongside `worker_pid`. An `erlang_module` step never sends this, so
the run's stored OS pid stays `undefined` and the in-BEAM teardown is unchanged.

This keeps the layering the README insists on: the run owns run state, the worker
reports facts back as messages, and the run never reaches into the worker.

### Killing the OS pid

In the `step_timeout` and `cancel` clauses of `waiting_tool/3`, after
`exit(WorkerPid, kill)`, if the stored OS pid is set, kill it. The kill itself is
a signal to a known pid — `os:cmd("kill -KILL " ++ integer_to_list(OsPid))` is
the v0.1-simple form and matches the one-shot scope (no process-group manager,
which is explicitly out of scope). A truly dead worker plus a killed OS pid means
no orphan survives.

This is additive. The `erlang_module` timeout/cancel paths keep working with no
OS pid to kill, so the existing `sleep`-based proofs stay green.

### Proving the external process is gone

A recorded-pid `kill -0` check is weak on its own — the issue says so, because OS
pids get reused. The strong proof is a side effect the helper produces only if it
runs to completion. The CLI test helper for these cases sleeps for longer than
the step budget and then writes a marker file. If the kill worked, the helper
died mid-sleep and the marker never appears; if the program leaked as an orphan,
the marker shows up after the sleep elapses.

So each "no longer alive" test: start a `cli` run whose helper is
`sleep N; touch marker`, drive the run to its terminal state, wait past the
helper's sleep window, then assert the marker file does not exist. The wait past
the sleep window is what distinguishes a killed process from a detached orphan
that is still counting down.

These new tests belong in a new suite,
`apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`, alongside the #18
`soma_cli_adapter_SUITE`. They go through the real session entry point
(`soma_agent_session:start_run/2`) and the real cancel path
(`SessionPid ! {cancel_run, RunId}`) so nothing bypasses a layer.

## Acceptance criteria → tests

### Criterion 1 — timed-out cli run reaches `timeout`
- Call chain: `soma_agent_session:start_run/2` → `soma_run_sup:start_run/1` →
  `soma_run` init → `executing/3` → `start_tool_call/7` → `soma_tool_call:start/1`
  → `run_cli/3` (port open) → step timer fires → `waiting_tool(state_timeout,
  step_timeout, ...)` → `timeout` state
- Test entry: `soma_agent_session:start_run/2` (no layer bypassed; the timer is
  armed inside `soma_run`, not by the test)
- Test: `test_cli_overrun_reaches_timeout` in
  `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`

### Criterion 2 — timed-out cli step leaves no live OS process
- Call chain: same as criterion 1 down to `waiting_tool(state_timeout,
  step_timeout, ...)`, which kills the worker and the captured OS pid; the helper
  is `sleep N; touch marker`
- Test entry: `soma_agent_session:start_run/2`; the liveness check is the marker
  file's absence read from the filesystem after the helper's sleep window, which
  is off the call chain because the proof is the helper's missing side effect, not
  a BEAM value
- Test: `test_cli_external_process_dead_after_timeout` in
  `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`

### Criterion 3 — cancelled cli run reaches `cancelled`
- Call chain: `soma_agent_session:start_run/2` → run starts the `cli` worker →
  run waits in `waiting_tool` → test sends `SessionPid ! {cancel_run, RunId}` →
  `soma_agent_session` `handle_info({cancel_run, RunId}, ...)` → `RunPid ! cancel`
  → `waiting_tool(info, cancel, ...)` → `cancelled` state
- Test entry: `soma_agent_session:start_run/2`, then the cancel message to the
  session's own interface (`{cancel_run, RunId}`), the cancel path the README
  names; no layer bypassed
- Test: `test_cli_cancel_reaches_cancelled` in
  `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`

### Criterion 4 — cancelled cli step leaves no live OS process
- Call chain: same as criterion 3 down to `waiting_tool(info, cancel, ...)`,
  which kills the worker and the captured OS pid; the helper is
  `sleep N; touch marker`
- Test entry: `soma_agent_session:start_run/2` then `{cancel_run, RunId}`; the
  liveness check is the marker file's absence read from the filesystem after the
  helper's sleep window, off the call chain for the same reason as criterion 2
- Test: `test_cli_external_process_dead_after_cancel` in
  `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`

### Criterion 5 — session survives, runs another cli run to completion
- Call chain: first run reaches `timeout` (or `cancelled`) as in criteria 1/3;
  then a second `soma_agent_session:start_run/2` on the same `SessionPid` runs a
  short `cli` step → `run.completed`
- Test entry: `soma_agent_session:start_run/2` called twice on one session;
  survival is `is_process_alive(SessionPid)` plus the second run reaching
  `run.completed`
- Test: `test_session_alive_runs_new_cli_run_after_timeout` and
  `test_session_alive_runs_new_cli_run_after_cancel` in
  `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`

### Criterion 6 — existing soma_runtime and soma_tools suites stay green
- Call chain: none (full suite run)
- Test entry: `rebar3 eunit && rebar3 ct`
- Test: the existing EUnit modules and CT suites under `apps/soma_runtime/test`
  and `apps/soma_tools/test`, unchanged. The OS-pid capture is additive — a
  worker with no `cli` port sends no OS pid and the run stores `undefined` — so
  the `sleep`-based `soma_run_failure_SUITE` timeout/cancel proofs and the #18
  `soma_cli_adapter_SUITE` happy path keep passing.

## Risks & trade-offs

- `os:cmd("kill -KILL ...")` spawns a short-lived shell to run `kill`. The core's
  no-shell rule is about how *tools* are launched (executable + argv, no
  interpolation), and the OS pid here is an integer the BEAM produced, not
  user-controlled text, so there is no interpolation surface. Still, it is a shell
  call in a codebase that otherwise avoids them. If that bothers review, the
  alternative is a port to `/bin/kill` with the pid as a literal argv element,
  which avoids the shell at the cost of more code. Either is fine for one-shot
  cleanup; the design does not need a process-group manager, which is out of
  scope.

- Killing only the captured OS pid does not kill grandchildren. If the CLI helper
  itself forks a child and exits, that grandchild can outlive the kill. v0.1's
  `cli` adapter is one-shot "run a program, take its stdout" — helpers that fork
  detached children are out of scope, and the test helper does not fork. A
  process-group kill would close this but is explicitly out of scope here.

- There is a window between `open_port` and the worker reporting the OS pid to the
  run. If teardown lands inside that window the run may not yet hold the OS pid.
  In practice the report is the worker's first act after the port opens, and the
  marker-file proof tolerates this: the test waits for `tool.started` before
  cancelling, and the helper's sleep is long enough that the report wins the race.
  If this proves flaky, the worker can capture and send the OS pid before
  entering `collect_cli/2`, which is already the plan.
