### Claude

## Verdict

changes-requested

## Real issues

- The service socket interns client input forever. `soma_service_socket:handle_request/1` feeds every in-cap frame to `soma_lfe:compile/2` at `apps/soma_actor/src/soma_service_socket.erl:97`, and `soma_lfe_reader` calls `list_to_atom/1` for every symbol at `apps/soma_lfe/src/soma_lfe_reader.erl:111`. A real-socket probe with 500 unique invalid operations raised the VM atom count from 12,524 to 13,024. Repeating that exhausts the atom table and kills both listeners plus every supervised task. The frame cap does not bound cumulative atom growth. Decode external names without creating atoms and pin the count with a socket regression.

- The adapter reports malformed lifecycle requests as server failures. `public_diagnostic_code/1` collapses `malformed_form` to `internal_error` at `apps/soma_actor/src/soma_service_socket.erl:148`. A framed `(status)` returned `(error (api-version "1") (code internal-error))`, while `docs/service-contract.md:47` promises `malformed_request` for an in-cap payload that is not a valid request. The same defect hits malformed `result` and `cancel` forms. Clients cannot distinguish their bad request from service corruption. Project service-form diagnostics to the fixed request error and cover the lifecycle forms over the socket.

- Watch destroys binary identity before the renderer can apply the published byte form. `soma_service_watch:wire_safe_binary/1` rewrites `<<255>>` to the ordinary string `<<"base64:/w==">>` at `apps/soma_actor/src/soma_service_watch.erl:97`. A production `page/4` plus `soma_lisp:render/1` probe emitted `(output "base64:/w==")`, contradicting the lossless `(bytes (hex "FF"))` rule in `docs/service-contract.md:22`. A real text payload with that prefix is indistinguishable from the rewritten bytes. Preserve the binary for `soma_lisp` and add an invalid-byte watch event to the real-socket proof.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: - [x] One end-to-end socket test: a framed `(invoke ...)` on a real service socket returns an accepted handle through the production `soma_service -> soma_run -> soma_tool_call` path with no LLM worker, a framed `(status ...)` returns the task's bounded terminal projection, and a framed `(result ...)` returns the task's exact inline output. Artifact: `soma_service_socket_SUITE:test_socket_invoke_status_and_result_end_to_end` and `test_socket_binary_results_use_lossless_lisp_bytes` passed in the 13-case focused socket suite; the first asserts the exact output and an empty LLM-start trace.
- Criterion 2 — pass: - [x] An accepted socket invocation reaches its normal terminal outcome after its client disconnects. Artifact: `soma_service_socket_SUITE:test_socket_disconnect_does_not_cancel_accepted_invocation` passed and asserts `run.completed` with no `run.cancelled` after the invoke connection closes.
- Criterion 3 — pass: - [x] A duplicate `(invoke ...)` on a new connection resolves to the original task with exactly one `run.started` event. Artifact: `soma_service_socket_SUITE:test_socket_duplicate_invoke_reuses_task_once` passed, compares task ids from separate connections, and counts one correlated `run.started` event.
- Criterion 4 — pass: - [x] A reconnecting `(watch ...)` returns the first bounded event page after its opaque cursor in durable append order. Artifact: `soma_service_socket_SUITE:test_socket_watch_reconnect_resumes_after_cursor` passed against a disk-backed store and compares both socket pages with the durable event-id order.
- Criterion 5 — pass: - [x] A repeated `(cancel ...)` returns the original cancelled projection after the owned CLI process exits. Artifact: `soma_service_socket_SUITE:test_socket_cancel_is_repeatable_after_cli_process_exit` passed, proves the BEAM worker and OS pid are dead before the first reply, and compares the repeated projection and event count.
- Criterion 6 — pass: - [x] One table-driven test: an invoke with an unsupported `api_version` returns a bounded typed error naming the supported version set, and an invalid operation returns its bounded typed error — both over the socket. Artifact: `soma_service_socket_SUITE:test_socket_version_and_operation_errors_are_typed` passed with unsupported-version and compiled `(run)` rows, exact `[<<"1">>]` advertisement, bounded frames, and no new `run.started` event.
- Criterion 7 — pass: - [x] One table-driven test: the listener survives a malformed Lisp frame and a request above the documented frame limit, answering each with its fixed bounded typed error and continuing to serve subsequent requests. Artifact: `soma_service_socket_SUITE:test_socket_rejects_bad_and_oversized_frames_then_serves` passed for zero-length, malformed Lisp, and over-cap rows and proves the same listener serves a fresh typed request after each.
- Criterion 8 — pass: - [x] One test: the production daemon starts the service listener only for a present `[service]` table, and the default service socket resolves to `service.sock` beside the CLI socket. Artifact: `soma_service_socket_SUITE:test_daemon_service_listener_is_config_opt_in_with_sibling_default` passed absent, present, malformed-table, and invalid-socket config rows against `soma_cli:daemon/1`.
- Criterion 9 — pass: - [x] One test: a service listener replaces a stale socket path only after proving no live server owns it, and a losing listener leaves the live winner serving the configured path. Artifact: `soma_service_socket_SUITE:test_service_socket_stale_takeover_and_lost_bind_preserve_winner` passed with a real stale AF_UNIX path, a replacement listener, a losing contender, and a fresh response from the winner.
- Criterion 10 — pass: - [x] One boundary-pin test: one production module owns the bounded frame codec for both socket listeners, one production module owns socket-path arbitration for both, and the service listener routes every operation through the `soma_lfe -> soma_service -> soma_lisp` boundary with no direct runtime execution import. The shared-transport extraction must leave the existing CLI wire suites — including cancel-on-disconnect — green and unchanged. Artifact: `soma_service_socket_boundary_tests:test_socket_adapters_share_transport_and_service_keeps_runtime_boundary` passed; `git diff --exit-code origin/main...HEAD -- apps/soma_actor/test/soma_cli_server_SUITE.erl` returned zero, and that unchanged suite passed all 47 cases.
- Criterion 11 — fail: - [x] `docs/service-contract.md` defines a machine-checked compatibility matrix for version negotiation, additive fields, typed errors, typed statuses, cursor resume, size limits, plus the support/deprecation rule. Artifact: `soma_service_contract_doc_tests:test_service_contract_defines_compatibility_matrix` passes its string checks, but a production watch-page probe rendered `<<255>>` as the ordinary string `"base64:/w=="` instead of the matrix's required `(bytes (hex "FF"))`; the published compatibility contract is false for watch replies.
- Criterion 12 — pass: - [x] `docs/contracts/RS.1d-test-contract.md` maps every acceptance criterion to its proving test. Artifact: `soma_rs1d_contract_doc_tests:test_rs1d_contract_maps_every_criterion_to_proving_case` passed in the 424-test EUnit gate and checks one heading and one full proof name for all twelve criteria.

Full local gate: `rebar3 eunit` passed 424 tests with 0 failures; `rebar3 ct` passed 517 tests with 0 failures. Focused runs passed all 13 `soma_service_socket_SUITE` cases and all 47 unchanged `soma_cli_server_SUITE` cases.
