### Claude

## Verdict
approve

## Real issues

None.

## Questions

- The design's "Contract + marker deliverables" section promised `docs/contracts/cli-5-test-contract.md` plus `soma_cli_5_contract_tests` and `soma_cli_5_marker_tests`. None of the three landed. The new CLI.5 test sources aren't on any existing marker scan list, so nothing pins them against a future network call sneaking in. The current sources are clean (`{local, _}` sockets only, no provider markers), so there's no defect today — but the convention every prior CLI slice carried is skipped here. Intentional, or dropped by accident?

- `per_user_id/0` prefers `$USER`, then `$LOGNAME`, then `id -u`. A daemon and a client for the same real user resolve different paths when their environments disagree — daemon with `$USER=joe` lands on `/tmp/soma-joe.sock`, a client launched with `$USER` stripped lands on `/tmp/soma-501.sock`. They never meet. The design called this out as a known trade-off and the criterion only locks same-env behavior, so it's not a blocker. Worth a follow-up: pick one source (the numeric uid is the stable one) instead of a precedence chain that can split.

- `--detach` parses fine on `status`/`trace`/`cancel` (parse_flags accepts it anywhere) but `detach_opt` only applies it to `run`/`ask`, so `status TaskId --detach` silently drops the flag instead of rejecting it. Harmless, but a malformed-but-accepted flag is a footgun. Leave it or reject it on read subcommands?

## Nits

- `dispatch(["run", "--detach"])` treats `--detach` as the File positional (a file literally named `--detach`). Same for `ask --socket`. Positional-first parsing makes this unavoidable without a real flag library; not worth fixing this slice.

## Functional evidence
- Criterion 1 — pass: `test_dispatch_run_file_completed_exit_zero` boots a real `soma_cli_server` on a temp socket, dispatches `["run", File]`, asserts the printed `(result ...)` reply and exit 0; CT suite green (10/10).
- Criterion 2 — pass: `test_dispatch_run_dash_reads_stdin` dispatches `["run", "-"]` with a fake IO server as group leader feeding the workflow on stdin, asserts exit 0.
- Criterion 3 — pass: `test_dispatch_ask_completed_exit_zero` dispatches `["ask", Intent]` against a server with a mock `model_config`, asserts `soma_cli:ask/1`'s exit code.
- Criterion 4 — pass: `test_dispatch_status_read_exit_zero` seeds a task via a real run, dispatches `["status", TaskId]`, asserts `(status (state ...))` reply and exit 0.
- Criterion 5 — pass: `test_dispatch_trace_read_exit_zero` seeds a correlation chain, dispatches `["trace", CorrId]`, asserts `(trace ...)` reply and exit 0.
- Criterion 6 — pass: `test_dispatch_cancel_running_task_exit_zero` seeds a detached running task, dispatches `["cancel", TaskId]`, asserts exit 0.
- Criterion 7 — pass: `test_dispatch_run_detach_marks_request` and `test_dispatch_ask_detach_marks_request` capture the wire bytes through `soma_cli_request_capture` and `re:run` matches the `(detach)` marker in the emitted request.
- Criterion 8 — pass: `test_dispatch_socket_override_wins` boots the server on `OverridePath` while `XDG_RUNTIME_DIR` points elsewhere with no listener; a successful `--socket OverridePath` status read proves the override beat the resolver.
- Criterion 9 — pass: `test_resolver_uses_xdg_runtime_dir` sets `XDG_RUNTIME_DIR` and asserts `soma_cli:resolve_socket(#{})` equals `filename:join(Dir, "soma.sock")`.
- Criterion 10 — pass: `test_resolver_per_user_path_stable_across_processes` unsets `XDG_RUNTIME_DIR`, matches `/tmp/soma-.+\.sock$`, and asserts a fresh `erl` subprocess resolves the identical path.
- Criterion 11 — pass: `test_resolver_per_user_path_not_from_getpid` asserts the resolved path does not contain `os:getpid()`, and a comment-stripped source scan of `soma_cli.erl` finds no `os:getpid()` call; the per-user branch reads `per_user_id/0` (USER/LOGNAME/`id -u`).
- Criterion 12 — pass: `test_daemon_and_dispatch_resolve_same_path` asserts `soma_cli:resolve_socket(#{})` equals `soma_cli_main:socket(#{})` with `XDG_RUNTIME_DIR` unset; both route through the shared `soma_cli:resolve_socket/1`.
- Criterion 13 — pass: `test_dispatch_ask_intent_with_quotes_round_trips` dispatches `["ask", "say \"hi\""]`; `soma_cli_intent:escape/1` produces `\"`, the daemon's `soma_lfe_reader` reads it back to `"`, the reply is `(status completed)` (not `error`), proving the string reached the daemon intact.
- Criterion 14 — pass: `test_dispatch_malformed_prints_usage_nonzero` over `[]`, `["bogus"]`, `["run"]` asserts non-zero exit, empty stdout, and a "usage" line on stderr (stdout/stderr captured by separate recording IO servers).
- Criterion 15 — pass: `test_dispatch_malformed_returns_integer` over the criterion-14 set plus `["run","f","--bogus"]` and `["run","f","--socket"]` asserts `is_integer(Exit)` for each; the `--socket`-with-no-value and unknown-flag cases route through `with_flags/2` to `usage/0` instead of a `function_clause`.
- Criterion 16 — pass: `test_main_halts_with_dispatch_code` source-scans `soma_cli_main.erl` — `main/1` exported, `halt(dispatch(` present, every `io:put_chars`/`io:format` names `standard_error`. Off-chain by necessity (a real `halt/1` kills the runner), matching the design's stated approach.
