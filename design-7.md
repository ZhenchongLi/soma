# [cc] Failure semantics: error, crash isolation, timeout, cancellation

## Current state

The happy path from issue #5 works. A run starts under `soma_run_sup`,
records `run.started`, walks its steps one at a time, and on the last step
records `run.completed` and reaches the `completed` state. The session tracks
the run and survives it finishing.

But `soma_run` only knows how to succeed. It has three state functions:
`executing/3`, `waiting_tool/3`, `completed/3`. There is no `failed`,
`timeout`, or `cancelled` state. `waiting_tool/3` has exactly one clause: it
matches `{tool_result, ToolCallId, WorkerPid, {ok, Output}}`. A tool that
returns `{error, Reason}` sends a `{tool_result, ..., {error, Reason}}`
message that matches no clause, so the run crashes with a `gen_statem` clause
error.

`soma_tool_call:start/1` spawns its worker with a plain `spawn`. The run does
not monitor it. So a tool that raises (the `fail` tool in `crash` mode) dies
without ever sending a reply, and the run sits in `waiting_tool` forever. There
is no timer on the wait either, so a slow tool (the `sleep` tool) also hangs
the run with no bound.

`soma_agent_session` handles only `{run_completed, RunId, Result}` and marks
that run `completed`. It has no `cancel_run` entry point and no handler for a
run that ended any other way. `get_status/1` would report any run it knows
about as `running` until it sees `run_completed`, so a failed run looks like it
is still going.

The `fail` tool (error and crash modes) and the `sleep` tool already exist from
issue #3, so the design needs no new tools.

## Approach

The whole point of the issue is that these four outcomes are modeled with
Erlang process machinery, not with `try/catch` scattered through the run. So:

**Monitor the tool-call worker.** `soma_tool_call:start/1` keeps spawning the
worker, but the run takes a monitor on the returned pid right after it starts
the worker. The monitor reference goes into the run's `#data`. Now the run
hears about three things while waiting: a normal `{tool_result, ...}` reply, a
`{'DOWN', Ref, process, Pid, Reason}` when the worker dies, and a step-timeout
message.

**Add the four terminal clauses.** `waiting_tool/3` grows three more clauses
next to the existing `{ok, Output}` one:

- `{tool_result, _, _, {error, Reason}}` — the tool returned an error. Record
  `tool.failed`, then `step.failed`, then `run.failed`. Tell the session
  `{run_failed, RunId, Reason}`. Move to the `failed` state.
- `{'DOWN', Ref, process, _Pid, Reason}` where `Reason =/= normal` — the worker
  crashed. Same three events, same `run_failed` message, same `failed` state. A
  crash and an `{error, _}` return land in the same terminal state, which the
  issue's first and third criteria both call `failed`.
- a step-timeout message — record `run.timeout`, kill the worker, tell the
  session, move to `timeout`.

A normal `'DOWN'` (reason `normal`) arrives right after a successful
`{tool_result, ..., {ok, _}}` because the worker exits cleanly once it has
replied. The run must ignore that one so it does not mistake a clean exit for a
crash. Easiest way: demonitor with `flush` when the `{ok, _}` reply is handled,
or match `Reason =:= normal` and keep waiting / ignore in the relevant states.

**Per-step timeout.** When the run starts a tool call in `executing/3`, it
reads `timeout_ms` from the step map and arms a timer. A `gen_statem` state
timeout fits: `{state_timeout, TimeoutMs, step_timeout}` set on entry to
`waiting_tool`. If the reply comes first, leaving `waiting_tool` cancels the
state timeout automatically. If the timer fires first, `waiting_tool` gets the
`step_timeout` event, and the run is still in `waiting_tool` so the active
worker pid is known. The run kills that worker (`exit(WorkerPid, kill)`),
records `run.timeout`, and moves to `timeout`. A step with no `timeout_ms` gets
no timer, matching today's unbounded wait for steps that don't ask for one.

**Cancellation.** `soma_agent_session` gains a `handle_info({cancel_run,
RunId}, State)` (the issue says cancel is sent to the session). It looks up the
run pid and sends the run a `cancel` message. The run handles `cancel` in
`executing` and `waiting_tool`. In `waiting_tool` it kills the active worker,
records `run.cancelled`, tells the session, and moves to `cancelled`. The
session records the run's status as `cancelled` and stays alive.

**Killing the worker, and proving it died.** Both timeout and cancel call
`exit(WorkerPid, kill)`. The run already monitors the worker, so after the kill
it will also get a `'DOWN'`. Once the run is in the `timeout` or `cancelled`
state that `'DOWN'` is just noise — the terminal state functions ignore stray
messages, the way `completed/3` does today. The test proves the worker is gone
with `is_process_alive(WorkerPid)` returning `false`; the test reads the worker
pid from the `tool.started`/`tool.failed` event the run records (the worker pid
already travels on tool events today).

**Per-outcome reports to the session.** The run tells the session its outcome
with a tagged message per outcome. The error case is named in the README:
`{run_failed, RunId, Reason}`. Timeout and cancel get their own tags — the
exact tags are the Dev's choice, the issue only requires `get_status/1` to
surface the right terminal status. `soma_agent_session` records `failed`,
`timeout`, or `cancelled` against the run in its `runs` map. `get_status/1`
already maps each run to its stored status, so once the session stores the
terminal status the right value comes out.

**Terminal states keep state, like `completed/3`.** Each new terminal state
function (`failed/3`, `timeout/3`, `cancelled/3`) does what `completed/3` does:
`{keep_state, Data}` for anything it gets. The run process stays alive in its
terminal state, so a test can confirm the outcome with `sys:get_state/1` or
from the event trail, whichever it prefers.

**A new run after a terminal one.** Nothing in the session blocks a second
`start_run` after the first ended badly. The session never linked to the run,
so a failed/timed-out/cancelled run leaves the session untouched. The new run
starts under `soma_run_sup` like any other and reaches `completed`. Note
`soma_run_sup` has `intensity => 1, period => 5`: that bounds *restarts*, and
runs are `temporary` (never restarted), so a terminal run does not spend the
budget. A fresh `start_child` is not a restart.

**Event fields.** Every event already flows through `soma_event_store:append/2`,
which fills in all eight mandatory fields (`normalize/1` defaults any missing
key to `undefined` and stamps `event_id` and `timestamp`). So the five new
event types carry all eight fields by construction. The criterion that asks for
this is satisfied as long as the run emits them through the store like the
existing events. The run should still pass the real `step_id` and
`tool_call_id` on the failure events, the same way the success events do today,
so those fields are not `undefined`.

## Acceptance criteria → tests

All tests run through the real session/run/tool-call layers: the test starts a
session with `soma_agent_session:start_link/1`, submits steps with
`soma_agent_session:start_run/2`, and reads outcomes from the event store or
`get_status/1`. None of them poke `soma_run` or `soma_tool_call` directly.
A new suite `soma_run_failure_SUITE` holds them, alongside the existing
`soma_run_happy_path_SUITE`.

### Criterion 1 — error return reaches `failed`, never `completed`
- Call chain: `soma_agent_session:start_run` → `soma_run_sup:start_run` →
  `soma_run` init → `executing/3` starts the `fail` tool in error mode →
  `soma_tool_call` worker returns `{error, Reason}` → `waiting_tool/3` error
  clause → `failed` state, `run.failed` event
- Test entry: `soma_agent_session:start_run` (full chain, nothing bypassed)
- Test: `test_error_return_reaches_failed_not_completed` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 2 — error run records `tool.failed`, `step.failed`, `run.failed` in order
- Call chain: same as Criterion 1; the run emits the three events in
  `waiting_tool/3`'s error clause before entering `failed`
- Test entry: `soma_agent_session:start_run`; the test reads the run-scoped
  trail with `soma_event_store:by_run/2` and checks the three indices ascend
- Test: `test_error_trail_tool_step_run_failed_in_order` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 3 — tool-call crash reaches `failed`
- Call chain: `soma_agent_session:start_run` → ... → `executing/3` starts the
  `fail` tool in crash mode → worker raises and dies → run's monitor delivers
  `{'DOWN', ..., Reason}` → `waiting_tool/3` DOWN clause → `failed` state
- Test entry: `soma_agent_session:start_run` (the crash is observed through the
  monitor the run holds, not staged by the test)
- Test: `test_tool_crash_reaches_failed` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 4 — session alive after a tool-call crash
- Call chain: same as Criterion 3; after the run reaches `failed` the test
  checks the session pid
- Test entry: `soma_agent_session:start_run`; then `is_process_alive(SessionPid)`
- Test: `test_session_alive_after_tool_crash` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 5 — over-budget tool reaches `timeout` and records `run.timeout`
- Call chain: `soma_agent_session:start_run` → ... → `executing/3` starts the
  `sleep` tool with `ms` larger than the step's `timeout_ms` and arms the state
  timeout → `waiting_tool/3` gets `step_timeout` before the reply → `timeout`
  state, `run.timeout` event
- Test entry: `soma_agent_session:start_run`; the step carries a small
  `timeout_ms` and a longer sleep so the timer wins
- Test: `test_overrun_reaches_timeout_records_run_timeout` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 6 — hung worker dead after timeout
- Call chain: same as Criterion 5; on `step_timeout` the run kills the active
  worker
- Test entry: `soma_agent_session:start_run`; the test reads the worker pid
  from the `tool.started` event for that run, waits for `run.timeout`, then
  asserts `is_process_alive(WorkerPid)` is `false`
- Test: `test_hung_worker_dead_after_timeout` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 7 — `{cancel_run, RunId}` drives run to `cancelled`, records `run.cancelled`
- Call chain: `soma_agent_session:start_run` → run starts a slow `sleep` step →
  test sends `{cancel_run, RunId}` to the session → session `handle_info` →
  `cancel` message to the run → `waiting_tool/3` cancel clause → `cancelled`
  state, `run.cancelled` event
- Test entry: the run is started through `start_run`; cancel enters at the
  session's message interface (`SessionPid ! {cancel_run, RunId}`), which is the
  real cancel path the README names
- Test: `test_cancel_run_reaches_cancelled_records_event` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 8 — active worker dead after cancel
- Call chain: same as Criterion 7; the cancel clause kills the active worker
- Test entry: `start_run`, then cancel through the session; the test reads the
  worker pid from the run's `tool.started` event, waits for `run.cancelled`,
  then asserts `is_process_alive(WorkerPid)` is `false`
- Test: `test_worker_dead_after_cancel` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 9 — session alive after cancel
- Call chain: same as Criterion 7; after the run reaches `cancelled` the test
  checks the session pid
- Test entry: `start_run`, cancel through the session, then
  `is_process_alive(SessionPid)`
- Test: `test_session_alive_after_cancel` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 10 — session runs a new run to `completed` after a bad one
- Call chain: one session, two `start_run` calls. First run ends `failed`,
  `timeout`, or `cancelled`. Second run is a plain echo step list and reaches
  `completed` through the normal happy path
- Test entry: `soma_agent_session:start_run`, called twice on the same session
- Test: `test_session_runs_new_run_after_failed`,
  `test_session_runs_new_run_after_timeout`,
  `test_session_runs_new_run_after_cancelled` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl` (three cases so each prior
  outcome is exercised; the issue allows one combined test, but three keeps a
  failure pinned to the outcome that broke it)

### Criterion 11 — the five failure events carry all eight mandatory fields
- Call chain: the failure events are emitted by `soma_run` through
  `soma_event_store:append/2`, which normalizes every event to the eight
  mandatory keys
- Test entry: `soma_agent_session:start_run` for each outcome; the test reads
  the events back with `soma_event_store:by_run/2` and checks every one of the
  eight keys is present on each of `tool.failed`, `step.failed`, `run.failed`,
  `run.cancelled`, `run.timeout`. Presence, not non-`undefined`: the store
  defaults unset keys to `undefined`, and not every field applies to every
  event (a `run.failed` has no `step_id`)
- Test: `test_failure_events_carry_eight_mandatory_fields` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 12 — `get_status/1` reports the terminal outcome, not `completed`
- Call chain: `start_run` → run reaches a terminal state → run reports its
  outcome to the session → session stores it → `get_status/1` maps the run to
  its stored status
- Test entry: `soma_agent_session:start_run`, then poll
  `soma_agent_session:get_status/1` until the run shows `failed`, `timeout`, or
  `cancelled`; assert it is never `completed`
- Test: `test_get_status_reports_terminal_outcome` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl` (one case per outcome, or
  a parameterized check over the three)

## Risks & trade-offs

**The normal `'DOWN'` after a successful reply.** A worker exits `normal` right
after sending its `{ok, _}` reply. The run now monitors the worker, so that
`'DOWN'` lands in the run's mailbox. If the DOWN clause is written to catch any
reason, it will fire on a healthy run and wrongly mark it failed. The fix is to
demonitor-and-flush when the `{ok, _}` reply is handled, or to match only
`Reason =/= normal`. The happy-path suite from #5 is the guard here: if this is
gotten wrong, those tests break, not just the new ones.

**Kill versus graceful stop.** Timeout and cancel use `exit(WorkerPid, kill)`,
the brutal kill. A tool mid-side-effect (a `file.write` halfway through) is cut
off with no chance to clean up. For v0.1 that is acceptable — cancellation being
*real* is the requirement, and a half-written sandbox file is the test fixture's
problem, not the runtime's. A graceful-stop protocol is a later concern, not
this issue.

**Timer races.** A step can finish in the same instant its timeout fires. With a
`gen_statem` state timeout, leaving `waiting_tool` cancels the pending state
timeout, so a reply that arrives first wins cleanly and no stale `step_timeout`
is delivered. If the design instead used a manual `erlang:start_timer`, a stale
timeout message could arrive after the reply and would have to be ignored in the
later state. The state-timeout route avoids that, which is why it is preferred.

**Error and crash collapse to one state.** `{error, _}` returns and worker
crashes both reach `failed`. That matches the issue (criteria 1 and 3 both say
`failed`) and the README's state diagram, which lists one `failed`. The
distinction between "the tool said no" and "the tool blew up" survives only in
the `run.failed` reason and the event payload, not in the state name. That is a
deliberate v0.1 simplification, not an oversight.
