### Claude

## Verdict
approve

## Real issues
None.

## Questions

- `handle_stop/1` returns the literal string `"(result (status stopped))"` instead of rendering through `soma_lisp:render/1` like every other handler. It works, and the wire bytes are correct, but if the result s-expr shape ever changes (`soma_lisp` adds a field, escaping rules shift) this one reply won't move with it. Deliberate, or just the shortest path to green?

## Nits

- `accept_loop/4` now wakes every 200ms forever (`gen_tcp:accept(ListenSocket, 200)` then recurse on `{error, timeout}`). An idle daemon spins one timer per 200ms. Cheap, but it trades a clean blocking accept for a poll. A `{select, ...}` or a longer timeout would idle quieter. Not load-bearing.

## Functional evidence
- Criterion 1 — pass: `soma_lfe_parser:parse_stop([stop])` returns `{ok, #{stop => #{}}}`; `soma_lfe:dispatch/1` routes a `stop`-headed form to it. Proven by `stop_compiles_to_stop_command_test` in `apps/soma_lfe/test/soma_lfe_cli_9_tests.erl` (eunit 249 green). No distribution, rpc, or signal — pure in-band parse.
- Criterion 2 — pass: `test_stop_returns_stopped_result` sends framed `(stop)` over the Unix socket and asserts the reply matches `^\(result ` and `\(status stopped\)`. CT `soma_cli_9_stop_SUITE` all 6 pass.
- Criterion 3 — pass: `test_after_stop_fresh_connect_fails` sends `(stop)`, reads the reply, then `connect_fails/2` polls a fresh `gen_tcp:connect` until it errors. Daemon no longer accepts. CT green.
- Criterion 4 — pass: `test_after_stop_socket_file_gone` polls `file:read_file_info(Path)` until `{error, enoent}` after stop. Listener's `file:delete(Path)` removes the AF_UNIX file. CT green.
- Criterion 5 — pass: `test_after_stop_start_link_rebinds_path` calls a fresh `soma_cli_server:start_link(#{socket => Path})` on the same path, asserts `{ok, _Rebound}`, then connects to confirm it listens. CT green.
- Criterion 6 — pass: `test_stop_cancels_active_detached_run` starts a detached `sleep 5000`, waits for `tool.started`, sends `(stop)`, then asserts `run.cancelled` lands in the store for that run id. `cancel_all/0` sends `RunPid ! cancel` to every running task — same lever as `cancel/1`. CT green.
- Criterion 7 — pass: `test_stop_kills_active_detached_tool_worker` captures `tool_call_pid` off `tool.started`, sends `(stop)`, waits for `run.cancelled`, then asserts `is_process_alive(WorkerPid)` is `false`. CT green.
- Criterion 8 — pass: `test_dispatch_stop_running_daemon_exit_zero` boots a server on the resolved per-run socket (no `--socket`), calls `soma_cli_main:dispatch(["stop"])`, captures printed `(result (status stopped))`, asserts `0 = Exit`, then polls `wait_for_connect_refused`. CT `soma_cli_dispatch_SUITE` all 11 pass.
