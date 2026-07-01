# CLI.1b Test Contract — full Lisp wire (`soma run` flow.lfe + `soma daemon`)

This document maps each proof of the CLI.1b slice (issue #110) to the suite or
module and the case that proves it. It is the companion to
[cli-test-contract.md](cli-test-contract.md) and follows the same shape as the
v0.x contracts ([v0.3-test-contract.md](v0.3-test-contract.md),
[v0.6-test-contract.md](v0.6-test-contract.md)).

## What this slice builds

The CLI wire becomes Lisp end to end — no JSON. `soma run flow.lfe` reads Soma
Lisp task source from the file and sends the file's s-expr to the daemon;
`soma_cli_server` parses it with `soma_lfe:compile/2`, runs it supervised under
`soma_run_sup` (owning the run, `session_pid => self()`), renders the outcome
with `soma_lisp:render/1` as a `(result ...)` s-expr, and the client prints it
and picks an exit code from the `(status ...)` sub-form. A malformed request
replies a defined `(result (status error) (error ...))` rather than crashing the
handler; the server survives both failed runs and malformed requests and answers
the next connection. `soma_cli:run/1` reads Soma Lisp task source from a `.lfe`
file or stdin (`-`); `soma_cli:daemon/1` boots the runtime and the listener on a
resolved socket path.

## Proving suites and modules

- **`soma_cli_server_SUITE`** — CT suite in `apps/soma_actor/test/`. Drives the
  full chain through a real `gen_tcp` client over a temp Unix socket: accept loop
  → `handle/1` → `soma_lfe:compile/2` → `soma_run_sup:start_run` → `soma_run` →
  `soma_tool_call` → `await_run` → `soma_lisp:render/1` → framed reply. No layer
  bypassed.
- **`soma_cli_server_tests`** — EUnit module in `apps/soma_actor/test/`. A
  source-text assertion over `soma_cli_server.erl`'s run path.
- **`soma_cli_SUITE`** — CT suite in `apps/soma_actor/test/`. Drives the
  `soma_cli` client (`run/1`, `daemon/1`) against a real `soma_cli_server` on a
  temp socket.
- **`soma_cli_1b_marker_tests`** — EUnit module in `apps/soma_actor/test/`. A
  source scan of the CLI.1b test files for real-provider / non-local-socket
  markers.
- **`soma_cli_1b_contract_tests`** — EUnit module in `apps/soma_actor/test/`.
  Pins this contract doc (`docs/contracts/cli-1b-test-contract.md`): asserts the
  file exists, is non-empty, and names every CLI.1b suite/module together with
  each of its case names.

## CLI.1b proofs → cases

| Criterion | Proof | Suite / module | Case |
| --- | --- | --- | --- |
| 1 | A completed run replies a `(result ...)` with `completed` status and the echo output | `soma_cli_server_SUITE` | `test_run_lisp_echo_returns_completed_result` |
| 2 | The completed `(result ...)` carries a non-empty `(correlation-id "...")` sub-form | `soma_cli_server_SUITE` | `test_run_lisp_result_carries_correlation_id` |
| 3 | `soma_cli_server` uses `soma_lfe` + `soma_lisp`, never `json:decode` / `json:encode` (whole module, CLI.1c) | `soma_cli_server_tests` | `cli_server_source_is_json_free_test` |
| 4 | A failed run replies a `(result ...)` with non-`completed` status and an `(error ...)` sub-form | `soma_cli_server_SUITE` | `test_run_lisp_failed_returns_error_result` |
| 5 | The server stays up after a failed run and answers the next request on a new connection | `soma_cli_server_SUITE` | `test_server_serves_after_failed_lisp_run` |
| 6 | A malformed Lisp request replies a defined error s-expr, no handler crash | `soma_cli_server_SUITE` | `test_malformed_request_returns_error_sexpr` |
| 7 | The server stays up after a malformed request and answers the next well-formed request | `soma_cli_server_SUITE` | `test_server_serves_after_malformed_request` |
| 8 | `soma_cli:run/1` reads Soma Lisp task source from a `.lfe` file, prints the `(result ...)`, returns exit 0 | `soma_cli_SUITE` | `test_run_echo_file_prints_result_exit_zero` |
| 9 | `soma_cli:run/1` returns non-zero when the run does not reach `completed` | `soma_cli_SUITE` | `test_run_failed_workflow_exit_nonzero` |
| 10 | `soma_cli:run/1` reads Soma Lisp task source from stdin when the path arg is `-`; stdin `soma run` input is Soma Lisp task source | `soma_cli_SUITE` | `test_run_reads_workflow_from_stdin_dash` |
| 11 | `soma_cli:daemon/1` boots the runtime + listener on a resolved path, a client connects | `soma_cli_SUITE` | `test_daemon_boots_listener_client_connects` |
| 12 | This contract (`docs/contracts/cli-1b-test-contract.md`) names a suite + case for each CLI.1b proof | `soma_cli_1b_contract_tests` | `test_doc_names_cli_1b_suites_and_cases` (the mapping table above is the deliverable) |
| 13 | Neither `docs/cli.md` nor `docs/contracts/cli-test-contract.md` describes a JSON wire for `soma run` | _docs deliverable_ | the prose in `docs/cli.md` and `docs/contracts/cli-test-contract.md` (Lisp `(run ...)` request / `(result ...)` reply; no test function) |
| 14 | CLI.1b test sources carry no real-provider marker and open no non-local socket | `soma_cli_1b_marker_tests` | `test_cli_1b_sources_have_no_real_provider_or_socket_marker` |

## Notes for the auditor

- **Criteria 12 and 13 are docs deliverables.** Criterion 12 is this file itself;
  it is pinned by `soma_cli_1b_contract_tests:test_doc_names_cli_1b_suites_and_cases`,
  which fails if any suite/module or case name above goes missing. Criterion 13 is
  satisfied by the prose in `docs/cli.md` and `docs/contracts/cli-test-contract.md`
  describing the Lisp wire and dropping the JSON-wire wording — no CT/EUnit case.
- **The `soma` escript/release entry is thin glue** over `soma_cli` and is
  exercised by the end-to-end path, not unit-tested, per the issue's out-of-scope
  note.
