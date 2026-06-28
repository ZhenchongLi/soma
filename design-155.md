# CLI.7b: soma_cli:ensure_daemon/2 — testable auto-start decide + wait

## Current state

CLI.7 (#152) gave a `soma` client command auto-start: when you run `soma run`
and no daemon is up, the wrapper brings one up before sending the request. That
logic lives entirely in the `soma` shell wrapper today. The wrapper probes the
socket, and if nothing answers it launches a detached daemon and waits for the
socket to come alive.

`soma_cli` already has the probe half. `soma_cli:ping/1` (#147) connects to
`{local, Path}`, closes immediately, and returns `0` when a `soma_cli_server`
is listening or `1` when nothing answers. What it does not have is the
decide-and-wait half: "if no one answers, launch and poll until one does, but
give up after a bound." That half is still shell code, so it never runs through
the `eunit` / `ct` gate.

The detached launch has to be a shell or OS spawn — you can't fork a detached
daemon process from inside an `eunit` test and have the gate stay hermetic. But
the launch is the only part that truly needs the shell. The decide-and-wait
around it is plain logic.

## Approach

Extract the decide-and-wait into `soma_cli:ensure_daemon/2`. The signature is
`ensure_daemon(#{socket => Path}, LaunchFun)`.

The launcher is a function argument, not a hardcoded spawn. That is the seam
that makes this testable. Tests pass a mock `LaunchFun` — one that starts a real
`soma_cli_server` in-process, or one that does nothing — and production later
passes the real detached spawn. The spawn itself is not built in this slice
(it's out of scope, a thin direct PR on top).

The flow:

1. Probe once with `soma_cli:ping(Args)`. If it returns `0`, a daemon is already
   up. Return `ok` and never touch `LaunchFun`.
2. If the probe returns `1`, call `LaunchFun` exactly once.
3. Poll `ping` on a bound — a fixed number of attempts with a short sleep
   between them. The moment a probe returns `0`, return `ok`.
4. If the bound runs out with no listener, return a bounded `{error, _}`. Never
   loop forever.

Reusing `ping/1` as the probe keeps one definition of "is a daemon up." The
launcher is called at most once: this slice decides and waits, it does not
retry-launch. If one launch doesn't bring a listener up within the bound, that's
the error case.

All of this lives in `apps/soma_actor/src/soma_cli.erl`. No new module, no
change to the one-way dependency.

## Acceptance criteria → tests

### Criterion 1 — already-listening returns ok without launching
- Call chain: test boots a real `soma_cli_server` on Path → `soma_cli:ensure_daemon(#{socket => Path}, LaunchFun)` → `soma_cli:ping/1` connects and returns `0` → `ensure_daemon` returns `ok` with `LaunchFun` untouched
- Test entry: `soma_cli:ensure_daemon/2` (no layer bypassed)
- Test: `test_ensure_daemon_already_listening_skips_launch` in `apps/soma_actor/test/soma_cli_7b_ensure_daemon_tests.erl`

The mock `LaunchFun` records whether it was called (it bumps a counter in an
`ets` table or sends a message to the test process). The assertion is two parts:
`ensure_daemon` returns `ok`, and the launcher was called zero times.

### Criterion 2 — launch once, then a listener comes up, returns ok
- Call chain: nothing listening at first → `soma_cli:ensure_daemon/2` → first `soma_cli:ping/1` returns `1` → `LaunchFun` runs and starts a `soma_cli_server` on Path → poll loop's `soma_cli:ping/1` returns `0` → `ensure_daemon` returns `ok`
- Test entry: `soma_cli:ensure_daemon/2` (no layer bypassed)
- Test: `test_ensure_daemon_launches_then_succeeds` in `apps/soma_actor/test/soma_cli_7b_ensure_daemon_tests.erl`

The mock `LaunchFun` is the thing that brings the listener up: it starts a real
`soma_cli_server` on Path and records that it was called once. The assertion is
`ensure_daemon` returns `ok` and the launcher was called exactly once. The test
must clean up the server it started (unlink, kill, delete the socket file), the
same teardown the ping tests use.

### Criterion 3 — launch never brings a listener up, bounded error, no hang
- Call chain: nothing listening → `soma_cli:ensure_daemon/2` → first `soma_cli:ping/1` returns `1` → `LaunchFun` runs but starts no listener → poll loop's `soma_cli:ping/1` returns `1` every attempt until the bound is exhausted → `ensure_daemon` returns `{error, _}`
- Test entry: `soma_cli:ensure_daemon/2` (no layer bypassed)
- Test: `test_ensure_daemon_launch_never_listens_returns_bounded_error` in `apps/soma_actor/test/soma_cli_7b_ensure_daemon_tests.erl`

The mock `LaunchFun` is a no-op (it starts nothing). The assertion is that
`ensure_daemon` returns `{error, _}`. The test wraps the call in an `eunit`
`{timeout, ...}` so a hang fails the test instead of stalling the gate — the
bounded poll must return before that timeout fires.

## Risks & trade-offs

The poll bound and sleep interval are a guess at how long a real detached daemon
takes to bind its socket. Set them too tight and a slow machine makes a healthy
auto-start report a false `{error, _}`. Set them too loose and Criterion 3's
failure path makes a user wait longer than necessary before giving up. This
slice picks a bound in the same range the ping tests already poll with (~80
attempts at 25ms). The real-spawn direct PR on top can revisit the numbers once
it measures an actual detached-daemon boot.

The launcher-as-argument seam means `ensure_daemon/2` never proves the real
detached spawn works — that's deliberate (the spawn is out of scope and can't
run on the gate), but it does mean the integration point between this logic and
the real launcher is only exercised by the follow-up direct PR's release smoke
test, not by `eunit` / `ct`.
