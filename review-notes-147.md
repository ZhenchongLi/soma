### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `daemon_foreground/1` now returns `ok` on every `{error, _}` from `start_link/1`, not only a lost bind. The design risk section calls this out: a socket-dir permission fault also exits silently. Fine for the auto-start race — the loser has no action either way — but the only safety net is "the winner's boot still surfaces the real fault." If the wrapper ever calls `daemon_foreground/1` as the sole daemon (not in a race), a misconfig becomes a silent clean exit. Confirm the wrapper always treats a `__ping` of `1` after auto-start as the real signal, not the daemon's exit code.

## Nits
- `usage/0` string still lists `<run|ask|status|trace|cancel|stop|daemon>` — correct, `__ping` is intentionally hidden. No change needed; noting so the next reader doesn't "fix" it.

## Functional evidence
- Criterion 1 — pass: `test_ping_returns_zero_when_listening` boots a real `soma_cli_server` on a unique-per-run path, polls until accepting, asserts `soma_cli:ping(#{socket => Path})` returns `0`. EUnit green (`soma_cli_7_ping_tests`, 2 tests 0 failures).
- Criterion 2 — pass: `test_ping_returns_one_when_nothing_listening` pre-deletes the socket file, no listener bound, asserts `soma_cli:ping(#{socket => Path})` returns `1`. EUnit green.
- Criterion 3 — pass: `test_daemon_foreground_lost_bind_returns_ok` boots a winner on Path, spawns a child running `daemon_foreground/1` on the same Path, monitors the child, asserts its DOWN reason is `normal` (not a `badmatch` crash). CT green. Code: `soma_cli.erl:188-201` turns `{error, _Reason}` into `ok`.
- Criterion 4 — pass: `test_lost_bind_leaves_original_listener_alive` — after the loser child exits `normal`, a fresh `gen_tcp:connect` to Path plus a framed `(stop)` round-trip gets `(status stopped)` back from the winner. CT green.
- Criterion 5 — pass: `test_dispatch_ping_returns_ping_exit_code` — `dispatch(["__ping"])` returns `0` with a listener on the resolver's `XDG_RUNTIME_DIR/soma.sock`, then `1` after the listener is torn down (bounded-polled to connect-refused). CT green. Code: `soma_cli_main.erl:83-90`.
- Criterion 6 — pass: `test_dispatch_ping_socket_override_wins` — listener on a distinct `OverridePath`, resolver's `soma.sock` deliberately unbound; `dispatch(["__ping", "--socket", OverridePath])` returns `0`, which can only happen if the override beat the resolver. CT green. Flag parse: `soma_cli_main.erl:125-126` via `with_flags`/`parse_flags`.
