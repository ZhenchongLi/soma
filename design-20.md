# [cc] v0.2: normalize CLI adapter failures into run failure data

## Current state

`soma_tool_call:run_cli/5` launches the external program and then blocks in `collect_cli/2`. It handles the happy path only.

Three operational failures are unhandled today:

1. `open_port({spawn_executable, Executable}, ...)` raises when the path does not exist or is not executable. The raise kills the worker. The worker dies before it sends any `{tool_result, ...}` reply, so the run learns of the death through the monitor's `'DOWN'`. That does reach `fail_run/5`, but the reason is a raw `badarg`/`eacces` port exception, not a reason that names the missing-executable or permission case.

2. `collect_cli/2` only matches `{Port, {exit_status, 0}}`. A non-zero exit status arrives as `{Port, {exit_status, N}}` with `N =/= 0` and matches nothing, so the worker blocks in the `receive` forever. The step's per-step timer eventually fires and the run records `run.timeout` — wrong terminal state for a program that exited with an error, and the exit status is lost.

3. `collect_cli/2` accumulates every `{data, Data}` chunk into `Acc` with no bound. A program that emits a lot of output makes the worker buffer all of it in memory.

The failure trail the issue wants to land on already exists and is correct. `soma_run:fail_run/5` emits `tool.failed -> step.failed -> run.failed` with `payload => #{reason => Reason}`, notifies the session, and moves the run to `failed`. It is already shared by the `{error, _}` return path and the worker-crash `'DOWN'` path (`soma_run.erl` lines 151-163, 235-247). The session already survives a failed run and accepts a new one (`soma_run_failure_SUITE` proves this for in-BEAM tools).

So nothing in `soma_run` needs to change. The whole issue lives inside `soma_tool_call`: turn each of the three failures into a clean, bounded `{error, Reason}` that the worker returns through its normal `{tool_result, ToolCallId, self(), {error, Reason}}` reply.

## Approach

Keep all changes inside `soma_tool_call`. The contract `soma_run` waits on does not change.

**Missing or non-executable path.** Wrap the `open_port` call in a `try`. The two raises map to two named reasons:
- path does not exist -> `{cli_executable_not_found, Executable}`
- path exists but is not executable -> `{cli_executable_not_executable, Executable}`

The exact exception class/term `open_port` raises for each case is what the implementation matches on; the design pins the two reason shapes, not the raw exception term. Because the worker now catches the raise and returns `{error, Reason}` instead of dying, the failure reaches the run as a `{tool_result, _, _, {error, Reason}}` reply rather than a `'DOWN'`. Both paths already land in `fail_run/5`, so the trail is identical either way; returning `{error, _}` is what lets the reason be a named one instead of a raw port exception.

**Non-zero exit.** Add a clause to the collect loop that matches `{Port, {exit_status, N}}` for any `N`. On `N =:= 0` return `{ok, Output}` as today. On `N =/= 0` return `{error, {cli_exit_status, N, Excerpt}}`, where `Excerpt` is the bounded captured output (see below). This stops the indefinite block, so a program that exits non-zero drives the run to `failed` with the status in the payload, not to `timeout`.

**Bounded output.** The collect loop carries a running byte count alongside the accumulator. A module-level constant sets the limit (the "configured byte limit"; a constant is enough for v0.1's scope — no per-tool override). Two things use the limit:
- When the program exits non-zero, the excerpt put in the reason is the captured output truncated to the limit. On a clean exit the full stdout is still the step output (the happy path is unchanged for outputs under the limit).
- When the accumulated bytes exceed the limit *before* the program exits, the worker stops collecting, kills the port, and returns `{error, {cli_output_limit_exceeded, Limit}}`. The reason names the limit. The worker does not keep buffering past the limit.

The captured output in a failure reason is always the truncated excerpt, never the full output. For the limit-exceeded case the reason carries the limit, not the output, so no failure payload ever holds the whole captured output.

On stderr: a `spawn_executable` port already merges stdout and stderr (`stderr_to_stdout` in `run_cli/5`). The excerpt is a bounded slice of that merged stream. That is the same merged output the happy path collects, so a failing program's diagnostic text is in the excerpt. True stdout/stderr separation needs a per-arch wrapper executable and is out of scope.

Reason shapes, fixed here so Dev and the tests agree:
- `{cli_executable_not_found, Executable}`
- `{cli_executable_not_executable, Executable}`
- `{cli_exit_status, N, Excerpt}` — `N` is the integer exit status, `Excerpt` the truncated merged output
- `{cli_output_limit_exceeded, Limit}` — `Limit` is the configured byte limit

## Acceptance criteria → tests

All new tests go in a new suite `soma_cli_failure_SUITE` under `apps/soma_runtime/test/`. It follows the existing CLI suites: `application:ensure_all_started(soma_runtime)` per case, helper scripts written to a temp dir, runs started through `soma_agent_session:start_run/2`, assertions read from the event store with `soma_event_store:by_run/2`. The "missing executable" and "not executable" cases need no helper script (one points at a non-existent path, the other at a non-`+x` file). The exit-status, diagnostic-output, and output-limit cases use small shell helpers like the ones the existing suites write.

### Criterion 1 — missing executable returns a named error, worker does not crash
- Call chain: `soma_agent_session:start_run/2` -> `soma_run` `executing` -> `start_tool_call/7` -> `soma_tool_call:start/1` -> worker `run_cli/5` -> `open_port` raises -> caught -> worker replies `{tool_result, _, _, {error, {cli_executable_not_found, _}}}`
- Test entry: `soma_agent_session:start_run/2` (full stack, no layer bypassed)
- Test: the step's `tool.failed` event carries `payload.reason` matching `{cli_executable_not_found, _}`, proving the worker returned a named error rather than dying with a raw port exception. The "worker did not crash" part is shown by the reason being the named one (a crash would surface the raw exception term through the `'DOWN'` path instead).
- Test: `test_missing_executable_named_error` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 2 — missing-executable run records tool.failed, step.failed, run.failed
- Call chain: same as Criterion 1, continuing `worker {error, _}` reply -> `soma_run` `waiting_tool` `{tool_result, ..., {error, Reason}}` clause -> `fail_run/5` -> emits `tool.failed` -> `step.failed` -> `run.failed`
- Test entry: `soma_agent_session:start_run/2`
- Test: read the run-scoped trail and assert the three event indices ascend `tool.failed < step.failed < run.failed`, same shape as `test_error_trail_tool_step_run_failed_in_order` in the existing failure suite.
- Test: `test_missing_executable_reaches_run_failed_trail` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 3 — file exists but not executable returns a permission error, run fails
- Call chain: `soma_agent_session:start_run/2` -> `soma_run` -> `soma_tool_call:start/1` -> `run_cli/5` -> `open_port` raises the permission case -> caught -> `{error, {cli_executable_not_executable, _}}` -> `fail_run/5` -> `run.failed`
- Test entry: `soma_agent_session:start_run/2`
- Test: write a file with mode `8#644` (readable, not `+x`), point the manifest's `executable` at it, run, then assert `run.failed` is in the trail and the `tool.failed` `payload.reason` matches `{cli_executable_not_executable, _}`.
- Test: `test_non_executable_permission_error` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 4 — non-zero exit reaches run.failed with the exit status in the payload
- Call chain: `soma_agent_session:start_run/2` -> `soma_run` -> worker `run_cli/5` -> `collect_cli/2` matches `{exit_status, N}` with `N =/= 0` -> `{error, {cli_exit_status, N, _}}` -> `fail_run/5` -> `run.failed`
- Test entry: `soma_agent_session:start_run/2`
- Test: helper script that does `exit 3`. Assert `run.failed` is in the trail and never `run.timeout` (the old code would block and time out). Assert the `tool.failed` `payload.reason` matches `{cli_exit_status, 3, _}`, so the exit status `3` is in the payload.
- Test: `test_non_zero_exit_carries_status` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 5 — failure payload carries a bounded excerpt of diagnostic output
- Call chain: same as Criterion 4; the helper prints diagnostic text before its non-zero exit, so `collect_cli/2` has captured that text when it builds `{cli_exit_status, N, Excerpt}`
- Test entry: `soma_agent_session:start_run/2`
- Test: helper prints a known short marker (well under the limit) to stdout, then `exit 1`. Assert the `tool.failed` `payload.reason` is `{cli_exit_status, 1, Excerpt}` and `Excerpt` contains the marker bytes — proving the merged captured output rode into the failure payload.
- Test: `test_failure_payload_carries_output_excerpt` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 6 — output over the limit stops the worker and names the limit
- Call chain: `soma_agent_session:start_run/2` -> `soma_run` -> worker `collect_cli/2` -> running byte count crosses the limit before exit -> worker kills the port and returns `{error, {cli_output_limit_exceeded, Limit}}` -> `fail_run/5` -> `run.failed`
- Test entry: `soma_agent_session:start_run/2`
- Test: helper that emits far more than the limit's worth of bytes (and would keep going / sleep, so a worker that kept buffering would not finish). Assert `run.failed` is in the trail and the `tool.failed` `payload.reason` matches `{cli_output_limit_exceeded, Limit}`, with `Limit` equal to the configured byte limit.
- Test: `test_output_over_limit_fails_with_limit_reason` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 7 — no failure payload holds the full captured output
- Call chain: same as Criteria 5 and 6 (both failure-reason builders)
- Test entry: `soma_agent_session:start_run/2`
- Test: helper emits more than the limit, then `exit 1`. Read the `tool.failed` `payload.reason`. If it is `{cli_exit_status, _, Excerpt}`, assert `byte_size(Excerpt) =< Limit`. If it is `{cli_output_limit_exceeded, Limit}`, assert the reason carries no captured output at all. Either way the full output is absent.
- Test: `test_failure_payload_never_holds_full_output` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 8 — session stays alive after a CLI failure and runs another run
- Call chain: first run `soma_agent_session:start_run/2` -> ... -> `run.failed`; then a second `soma_agent_session:start_run/2` on the same session pid -> ... -> `run.completed`
- Test entry: `soma_agent_session:start_run/2` (twice on the same session)
- Test: drive a first run to `run.failed` (the non-zero-exit helper from Criterion 4), assert `is_process_alive(SessionPid)`, then start a second short successful `cli` run on the same session and wait for `run.completed`. Same shape as `test_session_alive_runs_new_cli_run_after_timeout` in the lifecycle suite.
- Test: `test_session_alive_runs_new_run_after_cli_failure` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 9 — existing suites stay green
- Call chain: none (the existing suites run unchanged)
- Test entry: none — this is a regression guard, not a new test
- Test: the merge gate's `rebar3 eunit && rebar3 ct` runs `soma_cli_adapter_SUITE`, `soma_cli_lifecycle_SUITE`, and `soma_run_failure_SUITE`. They must all stay green. The happy-path `collect_cli` exit-0 clause and the unbounded-under-limit output behavior must not change for outputs below the limit.

## Risks & trade-offs

- **The two `open_port` raises must map to the right reasons.** `open_port` does not document a stable, separate error term for "missing" vs "not executable", and the term can differ across OS and Erlang version. If the implementation cannot tell the two cases apart from the raised term alone, it can `filelib:is_file/1` / check the mode before opening the port to decide which reason to use. That adds a stat call on the failure path only; the happy path is untouched. The criteria only require that the reason identifies the case, not how the case is detected.

- **The byte limit is a module constant, not configurable per tool.** That is the smallest thing that satisfies "a configured byte limit" and keeps the descriptor shape unchanged. If a later issue wants a per-tool limit, it moves the constant into the manifest. Calling that out so nobody treats the constant as a config surface it is not.

- **Killing the port on limit-exceeded leaves the external program to be reaped.** The worker closes/kills its port, but the OS child can outlive it. The run's existing OS-pid teardown (`kill_os_process/1`) only fires on timeout and cancel, not on this `{error, _}` return. For a program that exits on its own shortly after its pipe is closed this is harmless, but a program that ignores a closed stdout could linger. Pinning this as a known edge of the minimal adapter rather than expanding scope to cover orphan reaping on the error path.
