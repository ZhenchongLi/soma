### Claude

## Verdict
approve

## Real issues
None.

## Questions
- Criterion 3 burns up to 80 × 25ms of `timer:sleep` plus 80 connect attempts before it gives up — about 2s of real wall time. Fine for the test (30s timeout). For a real user it's a 2s stall before "daemon failed to start." The design doc flags it and hands tuning to the follow-up real-spawn PR. Confirming that's the intended split, not something to tighten here.

## Nits
- `ensure_daemon/2` has no clause for `ping/1` returning anything but `0` or `1`. `ping/1` is typed `non_neg_integer()` and only ever returns those two today, so this is a `function_clause` crash that can't fire. Leave it; adding a catch-all would be dead code.

## Functional evidence
- Criterion 1 — pass: `test_ensure_daemon_already_listening_skips_launch` boots a real `soma_cli_server` on a unique socket, passes a `LaunchFun` that messages the test process, asserts `ensure_daemon` returns `ok` and `count_launches()` is `0`. Green in `rebar3 eunit --module=soma_cli_7b_ensure_daemon_tests` (3 tests, 0 failures).
- Criterion 2 — pass: `test_ensure_daemon_launches_then_succeeds` starts nothing first; `LaunchFun` brings up a real `soma_cli_server` on `Path`; asserts `ensure_daemon` returns `ok` and exactly 1 launch recorded (`drain_launches`). Green in the same run.
- Criterion 3 — pass: `test_ensure_daemon_launch_never_listens_returns_bounded_error` uses a no-op `LaunchFun`, asserts `{error, _}` (impl returns `{error, daemon_not_listening}` after 80 × 25ms bound), wrapped in `{timeout, 30}` so a hang fails. Returns in ~2s, green in the same run.
