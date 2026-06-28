# [cc] CLI.9: soma stop — in-band daemon teardown over the Lisp wire

## Current state

The daemon has no clean stop. `soma_cli_server` exports `start_link/1`, `frame/1`,
`unframe/1`, and `ask_envelope/4`. There is no stop request and nothing closes the
listen socket.

The accept loop in `accept_loop/2` ends only on `{error, closed}` — the listen
socket closing. No code path ever closes it. So stopping the daemon means killing
the BEAM, which leaves the socket file on disk. The next boot's `unlink_stale/1`
probe has to reap that leftover before it can bind.

The wire already carries four request kinds the daemon parses with
`soma_lfe:compile/2`: `(run ...)`, `(ask ...)`, `(trace ...)`, `(status ...)`,
`(cancel ...)`. `soma_lfe:compile/2` routes a single top-level form on its head
atom in `dispatch/1`, and the parser turns each into a top-level command map
(`#{run => ...}`, `#{cancel => ...}`, and so on). `soma_cli_server:handle_lisp_request/3`
branches on those map keys. There is no `stop` head and no `#{stop => ...}` map.

Detached runs are owned by `soma_cli_task_registry` (a `gen_server`), which holds
each live run's pid and learns its terminal status from the `{run_completed |
run_failed | run_timeout | run_cancelled, RunId, ...}` messages `soma_run` sends.
`soma_cli_task_registry:cancel/1` already sends a bare `cancel` to a running run's
pid. That is the lever stop reuses to drain in-flight detached runs.

There is no `soma_cli:stop/1` thin client and no `stop` clause in
`soma_cli_main:dispatch/1`.

## Approach

Add `(stop)` as a fifth command on the same wire.

Parsing. `soma_lfe:compile(<<"(stop)">>, #{})` returns `{ok, #{stop => #{}}}`. The
reader already turns `(stop)` into the form list `[[stop]]`. We add one
`dispatch/1` clause in `soma_lfe.erl` that matches a top-level form headed by the
atom `stop`, and a `parse_stop/1` in `soma_lfe_parser.erl` that accepts the bare
`(stop)` and rejects `(stop ...)` with extra tokens. The command map's value is an
empty map, matching the shape of the other command maps. No payload to carry.

Teardown ownership. The handler process that parses `(stop)` is not the accept-loop
process that owns the listen socket. So the handler cannot close the listen socket
directly — it does not hold the socket. The listener (the process started in
`start_link/1` that runs `listen/3` then `accept_loop/2`) does. The handler signals
the listener to tear down, and the listener does the work it owns: close the listen
socket (which ends the accept loop), then unlink the socket file. We pass the
listener's pid down to each handler so the handler has someone to signal.

What teardown releases, in order:

1. Cancel in-flight runs. The stop handler asks `soma_cli_task_registry` to cancel
   every running detached task. Each `soma_run` tears down its own tool-call worker
   and external OS child and emits `run.cancelled` — the same path `cancel/1`
   already drives. Stop does not refuse while busy; it cancels.
2. Reply to the stopping client. The handler frames back `(result (status stopped))`
   so the client knows the daemon accepted the stop, before the listen socket goes.
3. Close the listen socket. The handler signals the listener; the listener closes
   the listen socket, so `accept_loop/2` falls into its `{error, closed}` clause and
   returns. No new connection is accepted after this.
4. Unlink the socket file. After the listen socket is closed, the listener deletes
   the socket file at its path. We keep the single-winner bind and the
   `unlink_stale` probe untouched — stop unlinks its own file on the way out, it
   does not switch the bind path to unconditional unlink.

Why the reply goes out before the close. The client reads one framed reply on its
connection. If we closed the listen socket first there would be a window where the
handler's own accepted socket is fine but the daemon is mid-teardown; sending the
reply first keeps the client's read deterministic. Closing the listen socket does
not disturb already-accepted connections, so the handler's own socket survives long
enough to flush the reply.

What stays out. We do not halt the daemon BEAM from inside the test gate — a test
must not halt its own runner. So the BEAM-exit half of `soma stop` is verified as a
`soma_cli_server` teardown operation: listen socket closed, socket file gone, path
rebindable. Mapping `soma stop` to the real foreground process exit and the name
collision with relx's `bin/soma stop` is CLI.6, out of scope here.

Client side. `soma_cli:stop/1` connects to the resolved socket, frames and sends
`(stop)`, reads the framed `(result (status stopped))` reply, prints it, and returns
exit 0 when the reply's status sub-form is `stopped`. `soma_cli_main:dispatch(["stop"
| Flags])` resolves the socket and drives `soma_cli:stop/1`, returning its exit code.

## Acceptance criteria → tests

### Criterion 1 — `(stop)` compiles to a stop command map
- Call chain: `none (direct compile call)` — `soma_lfe:compile(<<"(stop)">>, #{})`
  → `soma_lfe_reader:read_forms` → `dispatch/1` (stop head) → `parse_stop/1`
- Test entry: `soma_lfe:compile/2`. This is the top of the parse boundary; no layer
  is bypassed, the daemon parses through this same call.
- Test: `test_stop_compiles_to_stop_command` in
  `apps/soma_lfe/test/soma_lfe_cli_9_tests.erl`

### Criterion 2 — a `(stop)` request gets a terminal `stopped` reply
- Call chain: gen_tcp client → `accept_loop` → handler → `handle_lisp_request`
  → `soma_lfe:compile` (stop) → stop handler → `soma_lisp` render
- Test entry: a real `gen_tcp` client over the temp Unix socket sends framed
  `(stop)` and reads the framed reply. No layer bypassed.
- Test: `test_stop_returns_stopped_result` in
  `apps/soma_actor/test/soma_cli_9_stop_SUITE.erl`

### Criterion 3 — after stop, a fresh connect to the path fails
- Call chain: gen_tcp client sends `(stop)` → handler signals listener → listener
  closes listen socket → `accept_loop` ends. Then a fresh `gen_tcp:connect` to the
  same path.
- Test entry: the same real-socket client path as Criterion 2, then a second
  `gen_tcp:connect` that must error. No layer bypassed.
- Test: `test_after_stop_fresh_connect_fails` in
  `apps/soma_actor/test/soma_cli_9_stop_SUITE.erl`

### Criterion 4 — after stop, the socket file is gone from disk
- Call chain: gen_tcp client sends `(stop)` → handler signals listener → listener
  closes listen socket → listener unlinks the socket file. Then
  `file:read_file_info/1` on the path.
- Test entry: the real-socket client sends `(stop)`; the assertion reads
  `file:read_file_info(Path)` and expects `{error, enoent}`. The off-chain file
  check is the only way to observe the unlink — it is not on the reply path.
- Test: `test_after_stop_socket_file_gone` in
  `apps/soma_actor/test/soma_cli_9_stop_SUITE.erl`

### Criterion 5 — after stop, a new `start_link/1` on the path binds
- Call chain: gen_tcp client sends `(stop)` → listener closes listen socket and
  unlinks the file. Then `soma_cli_server:start_link(#{socket => Path})`.
- Test entry: the real-socket client sends `(stop)`, then a fresh
  `soma_cli_server:start_link/1` on the same path must return `{ok, _}`. A `{local,
  _}` connect to the new server confirms it listens. No layer bypassed.
- Test: `test_after_stop_start_link_rebinds_path` in
  `apps/soma_actor/test/soma_cli_9_stop_SUITE.erl`

### Criterion 6 — a detached run active at stop reaches `cancelled`
- Call chain: detached `(run ...)` → `soma_cli_task_registry` owns the run → then
  `(stop)` → stop handler → registry cancels every running task → `soma_run`
  cancels → `run.cancelled` in the event store.
- Test entry: a real-socket client starts a detached long `sleep`, waits (bounded)
  for that run's `tool.started`, then sends `(stop)`; the assertion polls the event
  store for `run.cancelled` on that run id. The store read is the observation seam,
  the same one the existing cancel cases use.
- Test: `test_stop_cancels_active_detached_run` in
  `apps/soma_actor/test/soma_cli_9_stop_SUITE.erl`

### Criterion 7 — that detached run's tool worker is dead after stop
- Call chain: same as Criterion 6 down to `run.cancelled`; the worker pid is read
  off the run's `tool.started` event via `tool_call_pid`.
- Test entry: same real-socket detached-run setup; capture the worker pid from
  `tool.started` in the store before stop, send `(stop)`, wait for `run.cancelled`,
  then assert `is_process_alive(WorkerPid)` is `false`. The worker pid is not on the
  reply path, so it is read from the event store.
- Test: `test_stop_kills_active_detached_tool_worker` in
  `apps/soma_actor/test/soma_cli_9_stop_SUITE.erl`

### Criterion 8 — `dispatch(["stop"])` drives `soma_cli:stop/1` and exits 0
- Call chain: `soma_cli_main:dispatch(["stop"])` → resolve socket →
  `soma_cli:stop/1` → gen_tcp client sends `(stop)` → daemon stop handler → framed
  `(result (status stopped))` reply → exit code.
- Test entry: `soma_cli_main:dispatch(["stop"])` against a real `soma_cli_server` on
  a unique per-run socket the dispatcher resolves itself (no `--socket` override).
  No layer bypassed.
- Test: `test_dispatch_stop_running_daemon_exit_zero` in
  `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

## Risks & trade-offs

The reply-before-close ordering has a narrow failure mode. If the handler crashes
between framing the reply and signalling the listener, the daemon is left running
with the client thinking it stopped. The handler is a plain spawned process with no
supervision, matching the existing per-connection handlers, so a crash there just
drops the teardown — it does not corrupt state. A retry of `soma stop` would land on
a still-live daemon and work. We accept this over adding a supervised teardown
coordinator for one request kind.

Cancel-not-refuse means a `soma stop` can cut off a long detached run a user did not
mean to lose. That is the decided fork. The run still emits `run.cancelled`, so the
loss is recorded in the trail, not silent.

The gate cannot prove the real BEAM exit. Criteria 3, 4, and 5 prove the daemon
released the listen socket, the socket file, and the path — everything a real
process exit would free except the OS process itself. The process-exit wiring lands
in CLI.6 and is verified there, not here. Until then, a packaged `soma stop` that
sends `(stop)` but never halts the BEAM would pass every test in this slice; that
gap is named and deferred, not closed.
