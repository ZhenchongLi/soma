### Claude

## Verdict
approve

## Real issues
None.

## Questions
- Cold-boot teardown in `test_cold_boot_registers_actor_sup` calls `supervisor:terminate_child(soma_actor_sup, Existing)` passing the *supervisor's own pid* as the child id on a `simple_one_for_one` sup. That returns `{error, not_found}` and the `ok =` match would crash — except the line is wrapped so it works only because the following `exit(Existing, shutdown)` does the real teardown. The `terminate_child` call is dead motion. Test passes regardless. Drop it or fix the intent in a later cleanup; not a blocker.

## Nits
- `daemon/1` and `daemon_foreground/1` now share four boot steps (runtime, socket, config, listener) and differ only in actor_sup-start + block. The design names this and defers a shared boot helper. Fine to leave.

## Functional evidence
- Criterion 1 — pass: `test_daemon_foreground_serves_stop_then_returns` spawns a child running `daemon_foreground/1`, a real `gen_tcp` client on `Path` sends framed `(stop)`, recv matches `^\(result ` and `\(status stopped\)`, then the child's `'DOWN'` fires within 5s proving the call returned and the BEAM process exited. Suite green (4/4).
- Criterion 2 — pass: `test_dispatch_daemon_blocks_then_exits_zero` runs `soma_cli_main:dispatch(["daemon","--socket",Path])` in a child, drives a real `(stop)`, and asserts the child reports `0 = Exit`. `dispatch/1` new clause returns `0` after `ok = soma_cli:daemon_foreground(...)`. Suite green.
- Criterion 3 — pass: `test_cold_boot_registers_actor_sup` asserts `undefined = whereis(soma_actor_sup)` before boot, then after a client connects asserts `is_pid` + `is_process_alive` on `whereis(soma_actor_sup)`. `daemon_foreground/1` calls `soma_actor_sup:start_link()` on the cold path. Suite green.
- Criterion 4 — pass: `test_warm_boot_tolerates_existing_actor_sup` starts `soma_actor_sup` first, boots `daemon_foreground/1`, serves a real client, and asserts `Sup0 =:= Sup1` (same pid, not replaced). `daemon_foreground/1` matches `{error,{already_started,_}} -> ok`. Suite green.
