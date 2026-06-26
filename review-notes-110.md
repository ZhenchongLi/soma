### Claude

## Verdict
changes-requested

## Real issues

- Default socket path uses the BEAM pid, not the UID. `soma_cli.erl:44`:
  `"/tmp/soma-" ++ os:getpid() ++ ".sock"`. `soma daemon` and `soma run` are
  separate `soma` invocations — separate BEAMs — so each resolves a different
  pid and a different `/tmp` path. They never meet. Both `docs/cli.md:65` and
  `design-110.md:129` specify `/tmp/soma-$UID.sock`; UID is stable across the
  client and daemon (same user) and is the correct rendezvous key. On macOS —
  the verified target — `XDG_RUNTIME_DIR` is unset, so this fallback is the path
  real usage hits. Result: a `soma run` started against a `soma daemon` with no
  explicit `--socket` cannot find the daemon. The acceptance criteria only test
  the override path (Criterion 11 passes a temp socket), so this slips past the
  gate, but it breaks the end-to-end CLI the slice exists to deliver. Use
  `os:getenv("UID")` / a stable user id, matching the docs.

## Questions

- `docs/contracts/cli-test-contract.md` proofs 1, 2, 8, 9, 10 still describe the
  JSON shaping (`encode_map ... matching JSON object`, `the reason tuple encodes
  to {"tag":...}`, `encode_response`). The wire prose at the top now says Lisp,
  so Criterion 13's check passes, but the proof table below still documents the
  legacy JSON run path. Is the dual JSON-or-Lisp wire (`dispatch_request/1`
  branching on first byte) meant to stay, or is the JSON branch dead weight to
  drop in a follow-up? If it stays, the table should say which proofs cover which
  wire; if it goes, these rows go with it.

- Criterion 3's source-text test (`test_run_path_uses_lisp_not_json`) slices only
  `handle_lisp_request/1`'s body and stops at the first blank line. The run path
  continues into `run_steps/1` (`soma_run_sup:start_run` + `soma_lisp:render`).
  `run_steps/1` calls no json, so the assertion holds, but the test under-scopes
  the path it claims to cover. If a future edit reintroduces `json:encode` inside
  `run_steps/1`, this test would not catch it. Worth widening the slice to the
  whole run path.

## Nits

- `soma_cli_server.erl` module doc (lines 1-7) still reads "this slice adds the
  pure term->JSON shaping layer; the Unix listener, framing, and run handler
  arrive in later cycles." Stale — the listener and run handler are here now and
  the wire is Lisp.

- `handle/1` comment (line 72) says "the payload here is the bare JSON." The
  payload is now a Lisp s-expr on the Lisp path.

## Functional evidence
- Criterion 1 — pass: `test_run_lisp_echo_returns_completed_result` (soma_cli_server_SUITE, 13/13 CT green) sends framed `(run (step s1 echo (args (value "hi"))))`, asserts reply matches `^\(result `, `\(status completed\)`, and `\(s1 \(value "hi"\)\)`.
- Criterion 2 — pass: `test_run_lisp_result_carries_correlation_id` asserts reply matches `\(correlation-id "[^"]+"\)` (non-empty quoted string).
- Criterion 3 — pass: `test_run_path_uses_lisp_not_json` (soma_cli_server_tests, EUnit 198/198 green) reads `handle_lisp_request/1` body: contains `soma_lfe:compile` and `soma_lisp:render`, no `json:decode`/`json:encode`. Note: scope is narrow (see Questions).
- Criterion 4 — pass: `test_run_lisp_failed_returns_error_result` sends a `fail`-step `(run ...)`, asserts `^\(result `, no `\(status completed\)`, and `\(error `.
- Criterion 5 — pass: `test_server_serves_after_failed_lisp_run` — first connection fails a run, second connection on a fresh socket gets `\(status completed\)`.
- Criterion 6 — pass: `test_malformed_request_returns_error_sexpr` sends `(nonsense foo bar)`, asserts reply `^\(result `, `\(status error\)`, `\(error `; handler does not crash. `handle_lisp_request/1` wraps `soma_lfe:compile` in try/catch.
- Criterion 7 — pass: `test_server_serves_after_malformed_request` — first connection garbage, second connection gets `\(status completed\)`.
- Criterion 8 — pass: `test_run_echo_file_prints_result_exit_zero` (soma_cli_SUITE, 4/4 CT green) writes echo `.lfe`, `soma_cli:run/1` prints a `(result ...)` with `(status completed)` and `(s1 (value "hi"))`, returns `0`.
- Criterion 9 — pass: `test_run_failed_workflow_exit_nonzero` runs a `fail` `.lfe`, asserts printed reply has no `(status completed)` and `Exit =/= 0`.
- Criterion 10 — pass: `test_run_reads_workflow_from_stdin_dash` feeds the workflow on a fake IO-server group leader, `run/1` with file `-` reads stdin, prints completed `(result ...)`, returns `0`.
- Criterion 11 — pass: `test_daemon_boots_listener_client_connects` stops the runtime, `soma_cli:daemon/1` reboots it (`whereis(soma_sup)` a pid) and binds the listener; a `{local, Resolved}` gen_tcp connect succeeds.
- Criterion 12 — pass: `docs/contracts/cli-1b-test-contract.md` maps all 14 criteria to suite + case (table lines 46-59); pinned by `test_doc_names_cli_1b_suites_and_cases` (soma_cli_1b_contract_tests).
- Criterion 13 — pass: `test_docs_describe_lisp_wire_not_json` asserts `docs/cli.md` and `docs/contracts/cli-test-contract.md` both contain `(run ` and `(result `, and neither contains `length-prefixed JSON` or `JSON wire`. (Residual JSON proof rows in the contract — see Questions.)
- Criterion 14 — pass: `test_cli_1b_sources_have_no_real_provider_or_socket_marker` (soma_cli_1b_marker_tests) scans the 5 CLI.1b sources: no `soma_llm_openai`/`api_key`/`base_url`/`http`/`https`, no `{inet`, no `gen_tcp:listen`, every `gen_tcp:connect(` is `{local,`. Grep over the scanned sources confirms zero marker hits.
