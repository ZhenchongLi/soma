### Claude

## Verdict

changes-requested

The happy paths work. The public failure contract does not.

## Real issues

- `soma_service_socket` lies about public failures. `dispatch/1` returns `internal_error` for every compiled non-service shape at `apps/soma_actor/src/soma_service_socket.erl:104`, and the allowlists at lines 124-129 preserve only two diagnostics and `not_found`. A real socket returned `internal-error` for `(run)`, `missing_api_version`, and `not_ready`. The same code collapses `request_id_conflict`, `result_unavailable`, `invalid_cursor`, `invalid_watch`, `not_running`, and `artifact_publish_failed`. Clients cannot distinguish a retryable result from server corruption. The criterion-6 row at `apps/soma_actor/test/soma_service_socket_SUITE.erl:346` never tests dispatch; it omits the invoke operation and gets a parser diagnostic. Preserve every published v1 code and test a compiled non-service form plus the service lifecycle errors.

- Oversized responses vanish. `handle/1` ignores `{error, frame_too_large}` from `soma_socket_frame:send/2` at `apps/soma_actor/src/soma_service_socket.erl:74` and closes the connection. A valid 2,977,208-byte inline result produced `{error, closed}` instead of the documented `response_too_large`. The caller sees a transport failure for a completed task and cannot apply the advertised smaller-page retry. Send the fixed fallback error and add a real-socket proof.

- The new `result` and `watch` compiler forms crash the CLI handler. `soma_lfe:compile/2` now returns successful maps for both, but the case at `apps/soma_actor/src/soma_cli_server.erl:424` handles neither and has no rejection clause. A real CLI socket request `(result "not-a-cli-task")` raised `case_clause` and returned EOF; the listener survived and served the next status request. This changes the CLI edge instead of keeping those service-only forms rejected. Add a bounded CLI rejection and a regression test for both forms.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: - [x] One end-to-end socket test: a framed `(invoke ...)` on a real service socket returns an accepted handle through the production `soma_service -> soma_run -> soma_tool_call` path with no LLM worker, a framed `(status ...)` returns the task's bounded terminal projection, and a framed `(result ...)` returns the task's exact inline output. Artifact: `soma_service_socket_SUITE:test_socket_invoke_status_and_result_end_to_end`; the focused suite passed all 9 cases.
- Criterion 2 — pass: - [x] An accepted socket invocation reaches its normal terminal outcome after its client disconnects. Artifact: `soma_service_socket_SUITE:test_socket_disconnect_does_not_cancel_accepted_invocation`; it asserts `run.completed` and no `run.cancelled` after the invoking connection closes.
- Criterion 3 — pass: - [x] A duplicate `(invoke ...)` on a new connection resolves to the original task with exactly one `run.started` event. Artifact: `soma_service_socket_SUITE:test_socket_duplicate_invoke_reuses_task_once`; the focused suite passed.
- Criterion 4 — pass: - [x] A reconnecting `(watch ...)` returns the first bounded event page after its opaque cursor in durable append order. Artifact: `soma_service_socket_SUITE:test_socket_watch_reconnect_resumes_after_cursor`; it compares both socket pages with the disk-backed event store's append order.
- Criterion 5 — pass: - [x] A repeated `(cancel ...)` returns the original cancelled projection after the owned CLI process exits. Artifact: `soma_service_socket_SUITE:test_socket_cancel_is_repeatable_after_cli_process_exit`; it checks the worker and OS pid are dead before the first reply and the second reply and event count are unchanged.
- Criterion 6 — fail: - [x] One table-driven test: an invoke with an unsupported `api_version` returns a bounded typed error naming the supported version set, and an invalid operation returns its bounded typed error — both over the socket. Artifact: `soma_service_socket_SUITE:test_socket_version_and_operation_errors_are_typed` passes only for an invoke missing its operation. A direct framed `(run)` probe returned `(error (api-version "1") (code internal-error))`, not `invalid-operation`.
- Criterion 7 — pass: - [x] One table-driven test: the listener survives a malformed Lisp frame and a request above the documented frame limit, answering each with its fixed bounded typed error and continuing to serve subsequent requests. Artifact: `soma_service_socket_SUITE:test_socket_rejects_bad_and_oversized_frames_then_serves`; the focused suite passed.
- Criterion 8 — pass: - [x] One test: the production daemon starts the service listener only for a present `[service]` table, and the default service socket resolves to `service.sock` beside the CLI socket. Artifact: `soma_service_socket_SUITE:test_daemon_service_listener_is_config_opt_in_with_sibling_default`; the focused suite passed.
- Criterion 9 — pass: - [x] One test: a service listener replaces a stale socket path only after proving no live server owns it, and a losing listener leaves the live winner serving the configured path. Artifact: `soma_service_socket_SUITE:test_service_socket_stale_takeover_and_lost_bind_preserve_winner`; the focused suite passed.
- Criterion 10 — pass: - [x] One boundary-pin test: one production module owns the bounded frame codec for both socket listeners, one production module owns socket-path arbitration for both, and the service listener routes every operation through the `soma_lfe -> soma_service -> soma_lisp` boundary with no direct runtime execution import. The shared-transport extraction must leave the existing CLI wire suites — including cancel-on-disconnect — green and unchanged. Artifact: `soma_service_socket_boundary_tests:test_socket_adapters_share_transport_and_service_keeps_runtime_boundary` passed; `soma_cli_server_SUITE` is unchanged against `origin/main` and passed all 47 cases.
- Criterion 11 — pass: - [x] `docs/service-contract.md` defines a machine-checked compatibility matrix for version negotiation, additive fields, typed errors, typed statuses, cursor resume, size limits, plus the support/deprecation rule. Artifact: `soma_service_contract_doc_tests:test_service_contract_defines_compatibility_matrix` passed in the 424-case EUnit gate.
- Criterion 12 — pass: - [x] `docs/contracts/RS.1d-test-contract.md` maps every acceptance criterion to its proving test. Artifact: `soma_rs1d_contract_doc_tests:test_rs1d_contract_maps_every_criterion_to_proving_case` passed in the 424-case EUnit gate.

Full local gate: `rebar3 eunit` passed 424 tests with 0 failures; `rebar3 ct` passed 513 tests with 0 failures.
