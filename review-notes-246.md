### Claude

## Verdict

changes-requested

## Real issues

- The service result wire is not Lisp for binary outputs. `soma_lisp:render_string/1` writes raw bytes between quotes at `apps/soma_event_store/src/soma_lisp.erl:233`. A real service-socket result for a one-byte `file_read` output of `<<255>>` produced an 80-byte frame that `soma_lfe_reader` rejected with `source is not valid UTF-8`. Artifact-backed results always hit the same defect because `truncated_inline` begins with external-term byte 131 at `apps/soma_actor/src/soma_service_artifact.erl:44`. Upstream clients cannot read valid task results. Define a lossless byte representation and prove inline plus artifact results over the real socket.

- `soma_socket_frame:recv/2` mishandles a zero-byte frame at `apps/soma_actor/src/soma_socket_frame.erl:16`. It passes length zero to `gen_tcp:recv/3`, whose zero-length mode waits for available bytes instead of returning `<<>>`. A real zero-length service frame returned `{error, timeout}` to the client after 300 ms and would hold the handler for its full 60-second receive timeout. It never sends the promised `malformed_request`. Handle zero explicitly and add it to the socket frame table.

- `[service]` enablement fails open. `classify/1` accepts the malformed header `[service` at `apps/soma_actor/src/soma_config.erl:112`, and `collect_service/3` silently discards a non-string `socket` value at lines 83-89. A production daemon started `service.sock` from a config containing only `[service` and `soma_config:load_service/1` returned `{enabled, #{}}` for `socket = 123`. A config typo exposes service ingress at the default path. Reject malformed tables and invalid service values before enabling the listener.

- Criterion 10 requires the existing CLI wire suite to stay unchanged. It did not: `apps/soma_actor/test/soma_cli_server_SUITE.erl` has 45 added lines against `origin/main`, including a new exported case and an `all/0` entry. Green is not unchanged. Restore that suite byte-for-byte and put the new service-only CLI rejection proof in a new test module or suite.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — fail: - [x] One end-to-end socket test: a framed `(invoke ...)` on a real service socket returns an accepted handle through the production `soma_service -> soma_run -> soma_tool_call` path with no LLM worker, a framed `(status ...)` returns the task's bounded terminal projection, and a framed `(result ...)` returns the task's exact inline output. Artifact: `soma_service_socket_SUITE:test_socket_invoke_status_and_result_end_to_end` passes for its ASCII value, but a real socket `file_read` result containing `<<255>>` produced `reader={error, <<"source is not valid UTF-8">>}` instead of a readable exact result.
- Criterion 2 — pass: - [x] An accepted socket invocation reaches its normal terminal outcome after its client disconnects. Artifact: `soma_service_socket_SUITE:test_socket_disconnect_does_not_cancel_accepted_invocation` passed and asserts `run.completed` with no `run.cancelled` after the invoke connection closes.
- Criterion 3 — pass: - [x] A duplicate `(invoke ...)` on a new connection resolves to the original task with exactly one `run.started` event. Artifact: `soma_service_socket_SUITE:test_socket_duplicate_invoke_reuses_task_once` passed, compares task ids from separate connections, and counts one correlated `run.started` event.
- Criterion 4 — pass: - [x] A reconnecting `(watch ...)` returns the first bounded event page after its opaque cursor in durable append order. Artifact: `soma_service_socket_SUITE:test_socket_watch_reconnect_resumes_after_cursor` passed against a disk-backed store and compares both pages with the durable event-id order.
- Criterion 5 — pass: - [x] A repeated `(cancel ...)` returns the original cancelled projection after the owned CLI process exits. Artifact: `soma_service_socket_SUITE:test_socket_cancel_is_repeatable_after_cli_process_exit` passed, proves the BEAM worker and OS pid are dead before the first reply, and compares the repeated projection and event count.
- Criterion 6 — pass: - [x] One table-driven test: an invoke with an unsupported `api_version` returns a bounded typed error naming the supported version set, and an invalid operation returns its bounded typed error — both over the socket. Artifact: `soma_service_socket_SUITE:test_socket_version_and_operation_errors_are_typed` passed with unsupported-version and compiled `(run)` rows, exact `[<<"1">>]` advertisement, bounded frames, and no new `run.started` event.
- Criterion 7 — fail: - [x] One table-driven test: the listener survives a malformed Lisp frame and a request above the documented frame limit, answering each with its fixed bounded typed error and continuing to serve subsequent requests. Artifact: `soma_service_socket_SUITE:test_socket_rejects_bad_and_oversized_frames_then_serves` passes for `"("` and an over-cap header, but a real in-cap zero-length frame received no typed error and timed out after 300 ms.
- Criterion 8 — fail: - [x] One test: the production daemon starts the service listener only for a present `[service]` table, and the default service socket resolves to `service.sock` beside the CLI socket. Artifact: the named daemon case passes for valid absent/present fixtures, but a production `soma_cli:daemon/1` probe with malformed `[service` still opened sibling `service.sock`; listener enablement is not limited to a present `[service]` table.
- Criterion 9 — pass: - [x] One test: a service listener replaces a stale socket path only after proving no live server owns it, and a losing listener leaves the live winner serving the configured path. Artifact: `soma_service_socket_SUITE:test_service_socket_stale_takeover_and_lost_bind_preserve_winner` passed with a real stale AF_UNIX path, a replacement listener, a losing contender, and a fresh typed response from the winner.
- Criterion 10 — fail: - [x] One boundary-pin test: one production module owns the bounded frame codec for both socket listeners, one production module owns socket-path arbitration for both, and the service listener routes every operation through the `soma_lfe -> soma_service -> soma_lisp` boundary with no direct runtime execution import. The shared-transport extraction must leave the existing CLI wire suites — including cancel-on-disconnect — green and unchanged. Artifact: `soma_service_socket_boundary_tests:test_socket_adapters_share_transport_and_service_keeps_runtime_boundary` passed and `soma_cli_server_SUITE` passed all 48 cases, but that existing suite has 45 added lines against `origin/main`, so it is not unchanged.
- Criterion 11 — pass: - [x] `docs/service-contract.md` defines a machine-checked compatibility matrix for version negotiation, additive fields, typed errors, typed statuses, cursor resume, size limits, plus the support/deprecation rule. Artifact: `soma_service_contract_doc_tests:test_service_contract_defines_compatibility_matrix` passed in the 424-case EUnit gate and checks every required matrix row plus the production version/frame constants.
- Criterion 12 — pass: - [x] `docs/contracts/RS.1d-test-contract.md` maps every acceptance criterion to its proving test. Artifact: `soma_rs1d_contract_doc_tests:test_rs1d_contract_maps_every_criterion_to_proving_case` passed in the 424-case EUnit gate and checks one heading and one full proof name for each of the twelve criteria.

Full local gate: `rebar3 eunit` passed 424 tests with 0 failures; `rebar3 ct` passed 516 tests with 0 failures. Focused proof runs also passed all 11 `soma_service_socket_SUITE` cases and all 48 `soma_cli_server_SUITE` cases.
