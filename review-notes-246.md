### Claude

## Verdict

changes-requested

## Real issues

- The no-new-atoms path is not total. `soma_lfe_reader:decode_atom/2` turns a fresh symbol into `{external_symbol, Binary}` at `apps/soma_lfe/src/soma_lfe_reader.erl:136`, then `parse_args/2` passes that tuple to the partial `coerce_value/1` at `apps/soma_lfe/src/soma_lfe_parser.erl:958`. A real framed invoke containing the otherwise valid canonical atom value `(args (value socket_fresh_value_975318642))` closed with EOF and logged a `function_clause` at `coerce_value/1`; the listener survived only because the handler is unlinked. The same source compiles and normalizes successfully through the ordinary RS.1a boundary. This is not a bounded typed rejection, and `test_socket_unknown_symbols_do_not_grow_atom_table` misses it because it exercises only an unknown top-level head. Make the safe reader/parser path total for a fresh symbol in every accepted position and add a real-socket nested-symbol regression.

- Atom safety currently changes valid requests according to VM history. On a fresh VM, a locked RS.1a steps invoke with `(id socket_fresh_step_975318642)` returned `(error ... (code invalid-operation))` over the production socket, while the same source passed `soma_lfe:compile/2` plus `soma_service_envelope:normalize/1` in the normal compiler mode. Fresh argument keys fail the same way. `existing_atoms_only` therefore supports a step id or key only if some unrelated earlier code happened to intern it. Step ids are caller-defined correlation data, not a registered vocabulary, and config-tool placeholder lookup already supports binary keys. Preserve the no-growth guarantee without making valid v1 invoke semantics depend on atom-table warm-up, and pin fresh step ids/from-step references and config-tool argument names through the real socket.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] One end-to-end socket test: a framed `(invoke ...)` on a real service socket returns an accepted handle through the production `soma_service -> soma_run -> soma_tool_call` path with no LLM worker, a framed `(status ...)` returns the task's bounded terminal projection, and a framed `(result ...)` returns the task's exact inline output.
  Artifact: `soma_service_socket_SUITE:test_socket_invoke_status_and_result_end_to_end` passed in the 519-case Common Test gate and asserts the accepted handle, exact echo result, terminal summary, and empty `soma_llm_call:start/1` trace. The named single-tool proof passes; the fresh-symbol and fresh-step counterexamples above remain uncovered compatibility failures.

- [x] An accepted socket invocation reaches its normal terminal outcome after its client disconnects.
  Artifact: `soma_service_socket_SUITE:test_socket_disconnect_does_not_cancel_accepted_invocation` passed and asserts `run.completed` with no `run.cancelled` after the invoke connection closes.

- [x] A duplicate `(invoke ...)` on a new connection resolves to the original task with exactly one `run.started` event.
  Artifact: `soma_service_socket_SUITE:test_socket_duplicate_invoke_reuses_task_once` passed, compares task ids from separate connections, and counts exactly one correlated `run.started` event.

- [x] A reconnecting `(watch ...)` returns the first bounded event page after its opaque cursor in durable append order.
  Artifact: `soma_service_socket_SUITE:test_socket_watch_reconnect_resumes_after_cursor` passed against the disk-backed event store, compares both pages with durable event-id order, and proves invalid bytes remain lossless while `base64:` text remains text.

- [x] A repeated `(cancel ...)` returns the original cancelled projection after the owned CLI process exits.
  Artifact: `soma_service_socket_SUITE:test_socket_cancel_is_repeatable_after_cli_process_exit` passed, proves the BEAM worker and OS pid are dead before the first reply, and compares the repeated projection and durable event count.

- [x] One table-driven test: an invoke with an unsupported `api_version` returns a bounded typed error naming the supported version set, and an invalid operation returns its bounded typed error — both over the socket.
  Artifact: `soma_service_socket_SUITE:test_socket_version_and_operation_errors_are_typed` passed with the exact `[<<"1">>]` advertisement, a compiled `(run)` invalid-operation row, bounded frames, and no new `run.started` event.

- [x] One table-driven test: the listener survives a malformed Lisp frame and a request above the documented frame limit, answering each with its fixed bounded typed error and continuing to serve subsequent requests.
  Artifact: `soma_service_socket_SUITE:test_socket_rejects_bad_and_oversized_frames_then_serves` passed for zero-length, malformed-Lisp, and over-cap rows and proves the listener serves a fresh request after each. A separate real-socket fresh-symbol probe produced EOF instead of any typed response, as described under Real issues.

- [x] One test: the production daemon starts the service listener only for a present `[service]` table, and the default service socket resolves to `service.sock` beside the CLI socket.
  Artifact: `soma_service_socket_SUITE:test_daemon_service_listener_is_config_opt_in_with_sibling_default` passed absent, present, malformed-table, and invalid-socket config rows through `soma_cli:daemon/1`.

- [x] One test: a service listener replaces a stale socket path only after proving no live server owns it, and a losing listener leaves the live winner serving the configured path.
  Artifact: `soma_service_socket_SUITE:test_service_socket_stale_takeover_and_lost_bind_preserve_winner` passed with a real stale AF_UNIX path, replacement listener, losing contender, and fresh response from the winner.

- [x] One boundary-pin test: one production module owns the bounded frame codec for both socket listeners, one production module owns socket-path arbitration for both, and the service listener routes every operation through the `soma_lfe -> soma_service -> soma_lisp` boundary with no direct runtime execution import. The shared-transport extraction must leave the existing CLI wire suites — including cancel-on-disconnect — green and unchanged.
  Artifact: `soma_service_socket_boundary_tests:test_socket_adapters_share_transport_and_service_keeps_runtime_boundary` passed in the 424-case EUnit gate; `git diff --exit-code origin/main...HEAD -- apps/soma_actor/test/soma_cli_server_SUITE.erl` returned zero, and the unchanged CLI suite passed inside the full Common Test gate.

- [x] `docs/service-contract.md` defines a machine-checked compatibility matrix for version negotiation, additive fields, typed errors, typed statuses, cursor resume, size limits, plus the support/deprecation rule.
  Artifact: `soma_service_contract_doc_tests:test_service_contract_defines_compatibility_matrix` passed its production-constant and matrix checks. The published v1 `(invoke ...)` promise is nevertheless false for fresh canonical step ids/argument symbols on the socket, so the document check does not clear the second Real issue.

- [x] `docs/contracts/RS.1d-test-contract.md` maps every acceptance criterion to its proving test.
  Artifact: `soma_rs1d_contract_doc_tests:test_rs1d_contract_maps_every_criterion_to_proving_case` passed in the 424-case EUnit gate and checks one heading and one full proof name for all twelve criteria.

Full local gate: `rebar3 eunit` passed 424 tests with 0 failures; `rebar3 ct` passed 519 tests with 0 failures. The green gate does not cover either safe-reader counterexample above.
