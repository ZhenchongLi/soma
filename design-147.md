# CLI.7: auto-start support — daemon liveness probe + graceful lost-bind

## Current state

CLI.6 shipped the packaged `soma` command and `soma daemon`. A user still has to run `soma daemon` once by hand before any client command works. CLI.7 wants a client command that finds no live daemon to start one itself. That auto-start decision lives in the `soma` shell wrapper, but the wrapper needs two Erlang pieces, and this slice builds and tests only those two pieces.

The first piece is a liveness probe. The wrapper has no way to ask "is a daemon already up on the resolved socket?". `soma_cli:ping/1` does not exist today. `soma_cli_main:dispatch/1` has no clause that drives a probe, so an unknown argv falls through to `dispatch(_Argv)` and returns the usage exit code 2.

The second piece is surviving a lost bind. When two client commands race to auto-start, both launch a daemon BEAM. Both call `daemon_foreground/1`. Both try to bind the same socket path. The kernel lets exactly one win. The loser's `soma_cli_server:start_link/1` returns `{error, _}`. Today `daemon_foreground/1` hard-matches `{ok, Server} = soma_cli_server:start_link(...)` (soma_cli.erl line 169), so the loser crashes with a `badmatch` instead of exiting cleanly. The server itself already handles this correctly: `unlink_stale/1` probes the path before binding and leaves a live listener's path alone (soma_cli_server.erl lines 51-63), so the loser's bind genuinely fails rather than stealing the path. The gap is only in `daemon_foreground/1`'s handling of that failure.

## Approach

Two small additions, both in `apps/soma_actor/src/`. No new module, no change to `soma_cli_server`.

### The probe — `soma_cli:ping/1`

Add `soma_cli:ping(#{socket => Path})`. It resolves the socket the same way every other client does, connects with `gen_tcp:connect({local, Path}, ...)`, and closes right away. It sends no request. A daemon is up when the connect succeeds. The function returns an integer exit code so the wrapper reads it straight from `$?`: 0 when the connect succeeds (a listener is there), 1 when it fails (nothing is listening). This matches the other client functions, which all return `non_neg_integer()` exit codes.

The probe sends nothing on purpose. A bare connect-and-close is the cheapest signal that a listener is bound. It also matches what `unlink_stale/1` already does on the server side to tell a live path from a stale one, so the two halves agree on what "alive" means.

### The lost-bind fix — `daemon_foreground/1`

Change the hard match into a case. When `soma_cli_server:start_link/1` returns `{ok, Server}`, do what it does today: monitor the listener and block until its `DOWN`. When it returns `{error, _}`, the path is already served by the winner, so this redundant daemon has nothing to do — return `ok` and let the process exit cleanly. A lost bind is data, not a crash.

This keeps the winner untouched. The loser's `unlink_stale/1` probe sees the winner answer and leaves the path alone, the bind fails, and `daemon_foreground/1` now turns that failure into a clean return instead of a badmatch.

### The dispatch clause — `__ping`

Add `dispatch(["__ping" | Flags])` to `soma_cli_main`. It parses trailing flags through the existing `with_flags/2` (so `--socket <path>` overrides the resolved socket exactly like every other verb), resolves the socket through `socket/1`, and calls `soma_cli:ping/1`, returning its exit code. The name is `__ping` with the double underscore because it is a wrapper-internal command, not a user-facing verb — it stays out of the usage line. The usage message in `usage/0` is unchanged.

## Acceptance criteria → tests

The two probe-result criteria (1 and 2) are EUnit unit tests on `soma_cli:ping/1` against a real socket — no daemon boot needed, just a `soma_cli_server` listener (or its absence). The lost-bind and dispatch criteria need the booted runtime and `soma_actor_sup`, so they go in a CT suite that mirrors the daemon-suite setup. Both suites use a unique per-run socket path (`$TMPDIR` + `os:getpid()` + `unique_integer` + pre-delete) under a new `soma_cli7_` prefix, and bounded polling instead of fixed sleeps.

### Criterion 1 — ping returns 0 when a daemon is listening
- Call chain: test boots `soma_cli_server:start_link/1` on Path → `soma_cli:ping(#{socket => Path})` → `resolve_socket/1` → `gen_tcp:connect({local, Path})` → connect succeeds → close → return 0
- Test entry: `soma_cli:ping/1` (the function under test, called directly with a real listener bound on Path)
- Test: `test_ping_returns_zero_when_listening` in `apps/soma_actor/test/soma_cli_7_ping_tests.erl`

### Criterion 2 — ping returns 1 when nothing is listening
- Call chain: test resolves a Path with no listener and no socket file → `soma_cli:ping(#{socket => Path})` → `gen_tcp:connect({local, Path})` → connect fails → return 1
- Test entry: `soma_cli:ping/1` (called directly against an unbound, pre-deleted Path)
- Test: `test_ping_returns_one_when_nothing_listening` in `apps/soma_actor/test/soma_cli_7_ping_tests.erl`

### Criterion 3 — daemon_foreground returns ok on a lost bind
- Call chain: test boots a winning `soma_cli_server` on Path → spawns a child running `soma_cli:daemon_foreground(#{socket => Path})` → `application:ensure_all_started` → `soma_actor_sup:start_link` (tolerated) → `resolve_socket/1` → `soma_cli_server:start_link/1` → `unlink_stale/1` sees the winner answer, leaves the path → bind fails → `{error, _}` → the new case returns `ok` → child exits
- Test entry: `soma_cli:daemon_foreground/1` (run in a child process so the test can monitor it; the winner listener is a real bound socket, not a stub). The child wrapper is off the chain only to observe "the call returned and the process exited" — the same monitor-the-child pattern the CLI.6 suite uses for `daemon_foreground/1`.
- Test: `test_daemon_foreground_lost_bind_returns_ok` in `apps/soma_actor/test/soma_cli_7_lost_bind_SUITE.erl`

### Criterion 4 — the original listener survives the lost race
- Call chain: same setup as Criterion 3 → after the loser's `daemon_foreground/1` child exits → test runs a fresh `gen_tcp:connect({local, Path})` and a framed `(stop)` round-trip against the winner
- Test entry: a fresh client connect to the winner's Path after the loser returned (the property is that the winner is untouched, so the test observes it from a fresh connection)
- Test: `test_lost_bind_leaves_original_listener_alive` in `apps/soma_actor/test/soma_cli_7_lost_bind_SUITE.erl`

### Criterion 5 — dispatch __ping drives ping and returns its exit code
- Call chain: test boots `soma_cli_server` on the resolver's path → `soma_cli_main:dispatch(["__ping"])` → `with_flags([], …)` → `socket/1` → `resolve_socket/1` → `soma_cli:ping/1` → connect succeeds → return 0; then the listener is torn down and `dispatch(["__ping"])` returns 1
- Test entry: `soma_cli_main:dispatch/1` (the dispatcher resolves the socket itself, no `--socket` override — same as the CLI.5 dispatch cases). The resolver is pointed at a unique per-run path through `XDG_RUNTIME_DIR`, mirroring `soma_cli_dispatch_SUITE`.
- Test: `test_dispatch_ping_returns_ping_exit_code` in `apps/soma_actor/test/soma_cli_7_lost_bind_SUITE.erl`

### Criterion 6 — dispatch __ping honours a trailing --socket override
- Call chain: test boots `soma_cli_server` on OverridePath while the resolver's `XDG_RUNTIME_DIR/soma.sock` has no listener → `soma_cli_main:dispatch(["__ping", "--socket", OverridePath])` → `with_flags(["--socket", OverridePath], …)` → `parse_flags` yields `#{socket => OverridePath}` → `socket/1` → `resolve_socket/1` returns OverridePath → `soma_cli:ping/1` connects to OverridePath → return 0
- Test entry: `soma_cli_main:dispatch/1`. A 0 here can only happen if the override beat the resolver, because the resolved path has no listener — the same proof shape `test_dispatch_socket_override_wins` uses in `soma_cli_dispatch_SUITE`.
- Test: `test_dispatch_ping_socket_override_wins` in `apps/soma_actor/test/soma_cli_7_lost_bind_SUITE.erl`

## Risks & trade-offs

A connect-only probe cannot tell a healthy daemon from a wedged one. A daemon stuck in a bad state but still accepting connections reads as "up", and the wrapper would not auto-start a replacement. CLI.7's scope is only "is something bound on the path", which is the right question for the auto-start race; a deeper health check is a separate concern and not in this slice.

The lost-bind fix swallows every `{error, _}` from `start_link/1`, not only the bind-already-taken case. A different startup failure (say a permission problem on the socket directory) would also return `ok` and exit silently rather than surfacing. The trade-off is deliberate for the race path — the loser has no useful action either way — but it means `daemon_foreground/1` no longer distinguishes a lost race from a misconfigured one. Given the only caller is the wrapper's auto-start, where a silent exit and a retry are acceptable, this is the simpler shape; a real misconfiguration still shows up on the winner's boot, which is the process the user is actually waiting on.

The two dispatch criteria depend on the resolver landing on the test's path through `XDG_RUNTIME_DIR`, which is process-global env. The suite saves and restores it per testcase, the same as `soma_cli_dispatch_SUITE`, so a parallel suite touching the same env is the only way this leaks — the CT gate runs suites in sequence, so this is not a live risk today.
