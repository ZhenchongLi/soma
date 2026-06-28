# [cc] CLI.6: daemon foreground lifecycle (daemon_foreground/1 + daemon verb)

## Current state

`soma_cli:daemon/1` boots the daemon and returns right away. It starts
`soma_runtime`, resolves the socket path, loads the model config, and calls
`soma_cli_server:start_link/1`. The listener runs in a process linked to the
caller, so `daemon/1` hands back `{ok, Path}` without ever blocking. That is the
right shape for a test that boots a server in its own process and keeps going,
but it is the wrong shape for a standalone daemon BEAM. A BEAM whose `main`
calls `daemon/1` would return, run off the end of its entry point, and halt
while the listener is still serving.

There is a second gap. The `ask` path in `soma_cli_server:handle_ask/2` calls
`soma_actor_sup:start_actor/1`, which only works if `soma_actor_sup` is
registered. Nothing in `daemon/1` starts it. Every daemon CT suite papers over
this by starting `soma_actor_sup` itself in `init_per_testcase` (see
`soma_cli_dispatch_SUITE` and `soma_cli_9_stop_SUITE`). A real standalone daemon
has no test harness to do that, so `ask` would crash on an unregistered
supervisor.

This issue is the testable Erlang core of packaging `soma` as a typable command.
The packaging shell — the relx rename to `somad`, the `bin/soma` wrapper, and
`main_argv/0` — is a separate direct PR and out of scope here, because a shell
wrapper and a `rebar.config` rename cannot be driven red→green by the
`eunit`/`ct` gate.

## Approach

Add `soma_cli:daemon_foreground/1`. It does what `daemon/1` does — start the
runtime, start `soma_actor_sup`, resolve the socket, load the model config,
start the listener — and then blocks until the listener exits. It monitors the
listener pid and waits for its `DOWN`. When the listener ends its accept loop
(a `(stop)` request closed the listen socket), the monitor fires and
`daemon_foreground/1` returns. So the BEAM the wrapper launched reaches the end
of its work and halts. A listener crash is a different path: the listener is
linked to the caller through `start_link`, so a crash propagates over the link
and takes the daemon process down with it, rather than being swallowed and
turned into a clean return.

`daemon_foreground/1` also starts `soma_actor_sup` if it is not already
registered, and tolerates the case where it is. The supervisor is registered
under a local name, so a second `start_link` returns
`{error, {already_started, Pid}}`. We treat that as success — the same pattern
the existing suites use in `init_per_testcase`. This closes the `ask` gap: a
standalone daemon that booted through `daemon_foreground/1` has a live
`soma_actor_sup` and can serve `ask`.

Add a `daemon` verb to `soma_cli_main:dispatch/1`. It parses the socket flag the
same way the other verbs do, calls `daemon_foreground/1`, and returns exit code
`0` once it comes back. Unlike the other verbs, this one blocks while the daemon
serves — it does not return until a `(stop)` tears the listener down.

`daemon/1` stays as it is. It is the non-blocking boot the CT suites lean on, so
removing it would churn every daemon test for no gain. `daemon_foreground/1` is
the blocking sibling for the standalone BEAM.

Why monitor rather than link the listener to the foreground caller and trap a
normal exit: a monitor `DOWN` carries the exit reason as data without needing
the caller to trap exits, and a `normal` reason on a linked process would not
deliver a signal the caller could wait on anyway. The link that `start_link`
already sets up stays — it is what turns a listener crash into a daemon crash.
The monitor is the additional handle for the normal-stop case.

## Acceptance criteria → tests

### Criterion 1 — daemon_foreground boots, serves a (stop), then returns
- Call chain: a test process spawns a child running
  `soma_cli:daemon_foreground(#{socket => Path})` → the child boots the runtime,
  `soma_actor_sup`, and the listener, then blocks on the listener monitor → a
  real `gen_tcp` client connects on `Path` and sends a framed `(stop)` →
  `soma_cli_server` accept loop → handler → `handle_lisp_request` →
  `soma_lfe:compile` parses `(stop)` → `handle_stop` signals the listener to
  close the listen socket and replies `(result (status stopped))` → the listener
  ends its accept loop and exits → the monitor `DOWN` fires →
  `daemon_foreground/1` returns → the child process terminates
- Test entry: the child process running `daemon_foreground/1`, with a real
  socket client driving the `(stop)`. No layer is bypassed. The child's
  termination is observed off the call chain through a monitor on the child pid,
  because "the call returned and the process exited" is the property under test
  and there is no return value to read from another process.
- Test: `test_daemon_foreground_serves_stop_then_returns` in
  `apps/soma_actor/test/soma_cli_6_foreground_SUITE.erl`

### Criterion 2 — dispatch(["daemon", "--socket", Path]) routes, blocks, returns 0
- Call chain: a test process spawns a child running
  `soma_cli_main:dispatch(["daemon", "--socket", Path])` → `dispatch/1` parses
  the socket flag and calls `soma_cli:daemon_foreground/1` → the daemon boots and
  blocks → a real `gen_tcp` client sends a framed `(stop)` on `Path` → the same
  server → handler → stop path → the listener exits → `daemon_foreground/1`
  returns → `dispatch/1` returns `0` → the child reports the exit code back
- Test entry: the child process running `dispatch/1`, with a real socket client
  driving the `(stop)`. No layer is bypassed. The exit code is captured by having
  the child send its `dispatch/1` return value back to the test process, because
  `dispatch/1` blocks and only returns after the stop, so the test reads the code
  after the child unblocks.
- Test: `test_dispatch_daemon_blocks_then_exits_zero` in
  `apps/soma_actor/test/soma_cli_6_foreground_SUITE.erl`

### Criterion 3 — soma_actor_sup is live after a cold boot
- Call chain: in a BEAM where `soma_actor_sup` was not registered beforehand, a
  child process runs `soma_cli:daemon_foreground(#{socket => Path})` → boot
  starts `soma_actor_sup` → `whereis(soma_actor_sup)` returns a live pid
- Test entry: `whereis(soma_actor_sup)` read from the test process after the
  daemon has booted, gated on a bounded poll for the listener accepting
  connections so the read happens after boot completed. The test first asserts
  `whereis(soma_actor_sup) =:= undefined`, then boots. If a prior case in the run
  left the supervisor registered, the case unregisters/stops it first so the
  "cold boot" precondition is real and not an accident of ordering.
- Test: `test_cold_boot_registers_actor_sup` in
  `apps/soma_actor/test/soma_cli_6_foreground_SUITE.erl`

### Criterion 4 — daemon_foreground boots cleanly when soma_actor_sup already up
- Call chain: a test process starts `soma_actor_sup` first, then a child runs
  `soma_cli:daemon_foreground(#{socket => Path})` → boot sees the already-started
  supervisor and tolerates it rather than crashing → the daemon serves
- Test entry: the test starts `soma_actor_sup`, asserts its pid is live, boots
  `daemon_foreground/1` in a child, then confirms the daemon serves a real client
  request on `Path` (proving boot did not crash on the already-started
  supervisor). The same supervisor pid is still registered after boot.
- Test: `test_warm_boot_tolerates_existing_actor_sup` in
  `apps/soma_actor/test/soma_cli_6_foreground_SUITE.erl`

The new suite mirrors the existing daemon suites: a unique per-run socket path
(`$TMPDIR` + `os:getpid()` + `unique_integer` + a pre-delete) under the
`soma_cli6_` prefix, bounded polling instead of fixed sleeps, and a hermetic
config — `SOMA_CONFIG` points at an absent path so the daemon loads no real
provider and opens no network. Because `daemon_foreground/1` blocks, every case
runs it in a spawned child and drives the lifecycle from the test process over a
real socket, the way the dispatch and stop suites already drive a real server.

## Risks & trade-offs

`daemon/1` and `daemon_foreground/1` now overlap — both boot the runtime,
`soma_actor_sup`, the socket, and the config. They differ only in the final
block-or-return step. Two near-identical boot bodies can drift. The honest
trade-off is keeping `daemon/1` non-blocking for the CT suites that depend on it
rather than collapsing both into one. If the duplication grows, a shared private
boot helper is the obvious follow-up, but that is not this issue's job.

The "cold boot" precondition in Criterion 3 is order-sensitive within a CT run.
`soma_actor_sup` is a named singleton, so once any earlier case registers it, a
later case cannot observe a true cold boot unless it tears the supervisor down
first. The test does that teardown explicitly. It is a real fragility to name,
not to hide: the proof depends on the supervisor genuinely being absent before
the boot.

A standalone daemon's clean exit on `(stop)` rests on the listener exiting
`normal`. If a future change makes the listener exit abnormally on a routine
stop, the `DOWN` reason would no longer be `normal`, and a foreground caller
that distinguishes reasons could mis-halt. This slice returns on any `DOWN`
reason, so it does not care about the reason today, but the coupling to "stop
ends the accept loop with a normal process exit" is worth stating.
