### Claude

## Verdict
approve

## Real issues

None.

## Questions

- On `main` the CLI handler started its run without `event_store`, so `soma_run`
  defaulted it to `undefined` and emitted no events at all — CLI runs were silent.
  This branch adds `event_store => event_store_pid()`, so CLI runs now leave a full
  trail. That's the right direction (events are mandatory per the design), and the
  cancel test reads `run.cancelled` straight off the store. Flagging it only so the
  silent-before/observable-after change is on record, not as a blocker.

## Nits

- `event_store_pid/0` is copied verbatim three times now: `soma_agent_session`,
  `soma_cli_server`, and the test suite. The session caches the pid in state once at
  init; the handler resolves it per connection. Same effective cost (one resolve per
  one-shot handler), so no consequence — but a shared helper would stop the third copy.
- `wait_for_new_tool_started_run/3` returns `{error, timeout}` on exhaustion instead
  of failing. If timing ever breaks, that tuple flows into `by_run/2` and the test
  dies later with a confusing match error rather than at the wait. A `ct:fail` on
  timeout would point at the real spot. Test-only.

## Functional evidence
- Criterion 1 — pass: `test_run_cancelled_on_client_disconnect` sends `(run (step s1 sleep (args (ms 5000))))` over a real gen_tcp client, waits for `tool.started`, closes the socket, then asserts `run.cancelled` for that run is in the store (`lists:member(<<"run.cancelled">>, Types)`). Handler clause `{tcp_closed, Socket} -> RunPid ! cancel` at soma_cli_server.erl:158 drives it. Green in `rebar3 ct`.
- Criterion 2 — pass: `test_worker_dead_after_client_disconnect` reads the worker pid off `tool.started` (`tool_call_pid`), disconnects, waits for `run.cancelled`, then asserts `false = is_process_alive(WorkerPid)`. The cancel reaches `soma_run`'s `waiting_tool` clause that does `exit(WorkerPid, kill)` — a real process kill, not a flag. Green.
- Criterion 3 — pass: `test_server_serves_after_client_disconnect` drops C1 mid-sleep, then a fresh C2 sends an echo run and `gen_tcp:recv` returns a frame matching `^\(result `, `\(status completed\)`, and `\(s1 \(value "ok"\)\)`. Green.
- Criterion 4 — pass: existing `test_run_lisp_echo_returns_completed_result` and `test_run_lisp_failed_returns_error_result` stay green — the four terminal-message clauses in `await_run` are unchanged, the `{tcp_closed, _}` clause is listed last so a finished run still replies. Both pass in the 13-case suite run.
- Criterion 5 — pass: `docs/contracts/cli-test-contract.md` gains a "Cancel-on-disconnect (CLI.1.5)" section (line 83) with a table mapping all three cases to their proofs; `soma_cli_1_5_contract_tests` asserts the section header, `CLI.1.5`, the suite name, and each of the three case names are present.
- Criterion 6 — pass: `rebar3 eunit` = 206 tests, 0 failures; `rebar3 ct` = 242 tests, 0 failures. Every new case uses `echo`/`sleep` tools and a temp local Unix socket only — no provider, no outbound network.
