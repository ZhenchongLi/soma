# CLI.1.5: cancel-on-disconnect — daemon cancels in-flight run when client drops

## Current state

`soma_cli_server`'s per-connection handler runs `handle/1`. It does one blocking
`gen_tcp:recv` for the framed request, calls `handle_lisp_request/1`, sends the
reply, and closes. The recv is the only time the handler looks at the socket.

For a `(run …)` request the reply path is `run_steps/1`. It mints the ids, starts
a `soma_run` it owns (`session_pid => self()`), then blocks in `await_run/3`.
`await_run/3` is a plain `receive` that matches only the four run terminal
messages (`run_completed` / `run_failed` / `run_timeout` / `run_cancelled`).

The gap: once the handler is inside `await_run`, it has stopped watching the
socket. The socket is `{active, false}` and nobody is reading it. If the client
drops mid-run, the handler doesn't notice. It keeps waiting, the run keeps
running its `sleep` step to completion, and an orphaned run nobody will read the
result of churns on the shared daemon. The README's "Connection / cancellation
semantics" promises a disconnect cancels the in-flight run. That promise isn't
kept yet. `docs/contracts/cli-test-contract.md` records it as deferred to CLI.1.5.

The real cancel path already exists and is proven. `soma_run`'s `waiting_tool`
state matches a bare `cancel` message: it kills the active tool-call worker
(`exit(WorkerPid, kill)`), kills any external OS process, records `run.cancelled`,
tells its `session_pid`, and moves to the `cancelled` terminal state.
`soma_agent_session` and `soma_actor` both reach it the same way — they send
`RunPid ! cancel` to the live run pid. This slice wires the handler to do the
same when the socket closes.

## Approach

Make the handler watch the socket while it waits for the run.

After the handler reads the framed request and starts the run, it flips the
socket to `{active, once}` with `inet:setopts(Socket, [{active, once}])`. With
`{active, once}` a client disconnect is delivered to the handler's mailbox as a
`{tcp_closed, Socket}` message instead of being invisible to a blocked
`{active, false}` socket. One `{active, once}` is enough — we only need the single
close event, not a stream, and the client sends nothing more after its request on
the synchronous path.

`run_steps/1` keeps the started run pid (today it discards it as `_RunPid`) and
threads both the run pid and the `Socket` into `await_run`. `await_run` grows one
more clause: on `{tcp_closed, Socket}` it sends `RunPid ! cancel` — the exact
message `soma_agent_session` and `soma_actor` send — and returns without a reply,
because the client that would read the reply is already gone. The four existing
terminal-message clauses are unchanged, so the connected-client paths
(echo completes, fail fails) behave exactly as before: the run finishes first,
its terminal message arrives, the handler frames the `(result …)` and sends it.

The cancel travels the real path. `RunPid ! cancel` reaches `soma_run`'s
`waiting_tool` cancel clause, which kills the live tool-call worker and records
`run.cancelled`. Nothing new is added to `soma_run` — this slice is entirely
inside `soma_cli_server`'s handler.

Tests verify the cancelled run through the event store, not the reply path,
because the disconnecting client never reads a reply. A fresh
`application:ensure_all_started(soma_runtime)` per case means the only run in the
store is the one the test drove, so the CT case lists the store, finds the
`tool.started` event, and pulls the run id and the worker pid off it. The worker
pid rides on `tool.started` as `tool_call_pid` (the same field
`soma_run_failure_SUITE` already reads to prove a killed worker is dead). That is
the test seam the issue's open question asks for — the event stream, not a reply
handle.

## Acceptance criteria → tests

All new cases live in `apps/soma_runtime/test/soma_cli_server_SUITE.erl` (CT, a
real `gen_tcp` client over a temp Unix socket — the suite's existing shape).

### Criterion 1 — disconnect mid-run drives the run to `cancelled`
- Call chain: gen_tcp client sends `(run (step s1 sleep (args (ms 5000))))` then
  `gen_tcp:close` → handler's `{active, once}` socket delivers `{tcp_closed,
  Socket}` → `await_run` cancel clause → `RunPid ! cancel` → `soma_run`
  `waiting_tool` cancel clause → `run.cancelled` recorded in the store
- Test entry: the gen_tcp client (full path, no layer bypassed). The assertion
  reads the store rather than a reply frame, because the disconnecting client
  never receives one.
- Test: `test_run_cancelled_on_client_disconnect` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 2 — the cancelled run's tool-call worker is dead
- Call chain: same chain as Criterion 1, asserting on the worker `soma_run`'s
  cancel clause killed. The test reads the worker pid from the run's
  `tool.started` event (`tool_call_pid`), waits for `run.cancelled`, then asserts
  `is_process_alive(WorkerPid)` is false.
- Test entry: the gen_tcp client. Worker liveness is read off the event store
  (the worker pid is not on the reply path), matching how
  `soma_run_failure_SUITE` proves a killed worker is gone.
- Test: `test_worker_dead_after_client_disconnect` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 3 — the server still serves a fresh connection after a disconnect
- Call chain: first client sends the sleep run then drops (the Criterion 1 chain);
  a second fresh client sends `(run (step s1 echo (args (value "ok"))))` →
  handler → `soma_lfe:compile` → `soma_run` → `soma_tool_call` (echo) →
  `await_run` (`run_completed`) → `soma_lisp:render` → framed `(result …)` reply
- Test entry: the second gen_tcp client reads the reply frame; the assertion is on
  the reply, not the store, since the second client stays connected.
- Test: `test_server_serves_after_client_disconnect` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 4 — a connected client still gets the framed `(result …)` reply
- Call chain: this is the existing connected-client path, unchanged by this slice.
  The two already-present cases prove it: `test_run_lisp_echo_returns_completed_result`
  (echo completes) and `test_run_lisp_failed_returns_error_result` (fail fails),
  both reading a framed `(result …)` reply over a connected socket.
- Test entry: the existing gen_tcp client cases (no new test needed; the design
  keeps the four terminal-message clauses untouched so they continue to pass).
- Test: `test_run_lisp_echo_returns_completed_result` and
  `test_run_lisp_failed_returns_error_result` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl` (existing, must stay green)

### Criterion 5 — the contract gains a cancel-on-disconnect proof section
- Call chain: none (direct source-file read). A new section in
  `docs/contracts/cli-test-contract.md` maps each new assertion to its CT case.
- Test entry: none — this is documentation, checked by reading the file.
- Test: the new "Cancel-on-disconnect (CLI.1.5)" section in
  `docs/contracts/cli-test-contract.md`, listing criteria 1–3 against their cases.

### Criterion 6 — gate is green, no real LLM or external network
- Call chain: none (gate run). `rebar3 eunit && rebar3 ct` over the cases above.
  Every case uses the mock-free runtime path (`echo` / `sleep` tools) and the
  local Unix test socket only — no provider, no outbound network.
- Test entry: none — this is the gate, not a single case.
- Test: the full suite under `rebar3 eunit && rebar3 ct`.

## Risks & trade-offs

- **Timing of the disconnect versus the step timeout.** The Lisp step grammar has
  no per-step `timeout_ms` field, so the sleep step runs under the `sleep` tool's
  manifest default of 1000ms. The test must drop the socket well inside that
  window, or the run reaches `timeout` instead of `cancelled` and the assertion
  fails for the wrong reason. The case sends the request and closes immediately,
  which is comfortably under 1000ms, but it should wait for the `tool.started`
  event before closing so the cancel lands in `waiting_tool` and not before the
  worker is spawned. This is the same "wait for `tool.started` first" guard
  `soma_run_failure_SUITE`'s cancel cases already use.

- **`{tcp_closed, Socket}` only arrives under `{active, once}`.** If the
  `inet:setopts` flip is missed or placed before the run starts, the close is
  never delivered and the handler waits out the run as it does today. The flip
  must happen after the run is started and before `await_run` blocks. Placing it
  inside `run_steps/1` right after `soma_run_sup:start_run` keeps it on that path.

- **A normal completion can race a late close.** If the run completes and its
  terminal message is already in the mailbox when a `{tcp_closed, Socket}` also
  arrives, the `receive` picks whichever clause matches a queued message first;
  the terminal-message clauses are listed before the `tcp_closed` clause, so a
  finished run still replies rather than being treated as a disconnect. This is
  ordering within one `receive`, not a guarantee about wall-clock arrival, and it
  is the right bias: a run that already finished should report its result.

- **Scope held to the synchronous case.** `--detach` (a client leaving keeps the
  task running) is explicitly out of scope. This slice only makes the synchronous
  `run` cancel on disconnect; the fire-and-forget mode is a later slice.
