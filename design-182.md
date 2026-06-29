## Current state

`soma_tool_call:start/1` currently uses `spawn/1` and returns only `{ok, Pid}`.
`soma_run:start_tool_call/7` emits `tool.started` and then calls
`erlang:monitor(process, WorkerPid)`.

That leaves a race for immediate crashes. The `fail` tool in crash mode raises
`error(Reason)`, so `(reason kaboom)` exits the worker with a crash term that
contains `kaboom`. If the worker dies before `soma_run` attaches its monitor,
the later monitor observes a dead pid and delivers `'DOWN'` with `noproc`
instead of the original crash reason. `soma_run:fail_run/5` then records that
observed reason in `tool.failed`, `step.failed`, `run.failed`, and sends it to
the owning session, actor, or CLI handler.

The CLI daemon path is affected because `soma_cli_server:run_steps/2` owns a
real `soma_run` directly (`session_pid => self()`), waits for
`{run_failed, RunId, Reason}`, and renders `Reason` as the `(error ...)` form in
the `(result ...)` reply. `examples/cli-demo/crash.lfe` drives exactly this path
with `(mode crash) (reason kaboom)`.

Existing tests prove that crashing tools fail runs and do not kill sessions,
actors, or the daemon, but they mostly assert terminal status or survival. They
do not pin the crash reason against the spawn/monitor race, and daemon coverage
uses `fail` error mode rather than immediate crash mode.

## Approach

Make worker creation and monitoring atomic at the `soma_run -> soma_tool_call`
boundary.

Change `soma_tool_call:start/1` to use `spawn_monitor/1` and return
`{ok, WorkerPid, MonitorRef}`. `spawn_monitor/1` is called by the `soma_run`
process, so the monitor belongs to the run from the first scheduler-visible
moment of the worker's life. This preserves the existing process boundary and
does not catch tool exceptions inside the worker.

Update `soma_run:start_tool_call/7` to accept `{ok, WorkerPid, MRef}` from
`soma_tool_call:start/1`, remove the separate `erlang:monitor/2` call, and store
that returned monitor ref in `#data.worker_mref`. Keep the current ordering of
`tool.started`, timer setup, timeout handling, cancellation handling, success
demonitoring, and `fail_run/5`.

The failure payload should continue to carry the actual monitor reason. For
`error(kaboom)`, that reason is an Erlang crash term containing `kaboom`
(`{kaboom, Stack}` on current OTP), not necessarily the bare atom. Tests should
therefore assert that the recorded/rendered reason contains `kaboom` and does
not contain `noproc`.

Do not change:

- the one-process-per-tool-call boundary;
- `soma_agent_session`, `soma_actor`, or `soma_cli_server` ownership semantics;
- timeout, cancellation, clean success, or CLI adapter behavior;
- failure normalization for tools that return `{error, Reason}`.

## Acceptance criteria → tests

| Criterion | Planned test coverage |
| --- | --- |
| Repeated immediate `fail` crash runs record `kaboom` in every `run.failed` payload, deterministically. | Add `test_repeated_immediate_tool_crash_preserves_real_reason/1` to `apps/soma_runtime/test/soma_run_failure_SUITE.erl`. It should start many one-step runs using `fail` with `#{mode => crash, reason => kaboom}`, wait for each `run.failed`, and assert each payload reason contains `kaboom` and does not contain `noproc`. |
| A real `soma_cli_server` request for the `crash.lfe` body returns `(result (status failed) ... (error ...kaboom...))`, not `(error noproc)`. | Add `test_run_crash_lfe_body_returns_kaboom_error_result/1` to `apps/soma_actor/test/soma_cli_server_SUITE.erl`. It should start a real local socket server, send the contents of `examples/cli-demo/crash.lfe` over a real client connection, and assert the reply is headed by `(result ...)`, has `(status failed)`, contains `kaboom`, and does not contain `noproc`. |
| After an immediate tool crash, the owning session/actor and daemon survive, and a subsequent run on the same daemon completes. | Add `test_session_runs_new_run_after_immediate_tool_crash/1` to `apps/soma_runtime/test/soma_run_failure_SUITE.erl` for the session-owned path. Add `test_actor_runs_new_run_after_immediate_tool_crash/1` to `apps/soma_actor/test/soma_actor_SUITE.erl` for the actor-owned path. Add `test_server_serves_after_crash_lfe_run/1` to `apps/soma_actor/test/soma_cli_server_SUITE.erl` to send the `crash.lfe` body, then on the same daemon send a fresh echo or pipeline request and assert it completes. |

Run the focused checks first:

- `rebar3 ct --suite apps/soma_runtime/test/soma_run_failure_SUITE`
- `rebar3 ct --suite apps/soma_actor/test/soma_actor_SUITE`
- `rebar3 ct --suite apps/soma_actor/test/soma_cli_server_SUITE`

Then run the normal gate:

- `rebar3 eunit`
- `rebar3 ct`

## Risks & trade-offs

Changing `soma_tool_call:start/1` from `{ok, Pid}` to `{ok, Pid, MRef}` is a
small internal API change. Current code only calls it from `soma_run`, so the
blast radius is narrow; if that changes, the compiler will catch unmatched
callers because warnings are errors.

`tool.started` will still be emitted after the worker is spawned. For an
immediate crash, the worker may already be dead by the time the event is
emitted, but the event still carries the real worker pid and the queued monitor
message still carries the real crash reason. This preserves existing event shape
without introducing an acknowledgement handshake that would change clean success
latency and worker behavior.

The rendered crash reason includes stack data because `fail` crash mode uses
`error(Reason)`. The tests should avoid asserting an exact serialized stack
shape, which is OTP-version-sensitive, and should instead pin the stable
contract: `kaboom` is present and `noproc` is absent.

This fix intentionally does not wrap `Module:invoke/2` in `try/catch`. A tool
crash remains a real process crash observed by the run's monitor, which keeps
the runtime's supervision and failure-isolation model intact.
