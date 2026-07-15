# RS.1d Test Contract — Unix-socket service adapter and compatibility

This document maps every acceptance criterion of the RS.1d service-socket
slice (issue #246) to the test case that proves it. The socket adapter owns
bounded transport and public service projection; `soma_service` retains task
ownership, and the runtime retains tool execution and resource teardown.

## Criterion 1 — invoke, status, and inline result work over the real socket

| Guarantee | Proof |
| --- | --- |
| Separate framed AF_UNIX requests invoke an allowed tool, observe its successful lifecycle, and return the exact inline result through the production service and runtime layers without starting an LLM worker. | `soma_service_socket_SUITE:test_socket_invoke_status_and_result_end_to_end` |

## Criterion 2 — disconnect does not cancel accepted service work

| Guarantee | Proof |
| --- | --- |
| Closing the invoking connection leaves the accepted task under service ownership, allowing it to complete normally and be observed from a new connection without a disconnect-driven cancellation. | `soma_service_socket_SUITE:test_socket_disconnect_does_not_cancel_accepted_invocation` |

## Criterion 3 — duplicate invoke on a new connection reuses one run

| Guarantee | Proof |
| --- | --- |
| Byte-identical invokes carrying one request id return the same task id across connections and produce only one durable run start. | `soma_service_socket_SUITE:test_socket_duplicate_invoke_reuses_task_once` |

## Criterion 4 — watch reconnect resumes after its opaque cursor

| Guarantee | Proof |
| --- | --- |
| A watch request returns durable events in append order, and a later connection resumes exclusively after the event represented by the first page's opaque cursor. | `soma_service_socket_SUITE:test_socket_watch_reconnect_resumes_after_cursor` |

## Criterion 5 — repeated socket cancellation preserves the cleaned terminal task

| Guarantee | Proof |
| --- | --- |
| Socket cancellation replies only after the run worker and external CLI process are gone, and a repeated cancellation returns the same stored terminal projection without another event. | `soma_service_socket_SUITE:test_socket_cancel_is_repeatable_after_cli_process_exit` |

## Criterion 6 — version and operation errors are typed over the socket

| Guarantee | Proof |
| --- | --- |
| An unsupported API version advertises the exact supported set, and a compiled non-service operation returns `invalid_operation`; neither request starts a run. | `soma_service_socket_SUITE:test_socket_version_and_operation_errors_are_typed` |

## Criterion 7 — malformed and oversized frames do not kill the listener

| Guarantee | Proof |
| --- | --- |
| Malformed Lisp and an over-cap declared frame receive fixed typed errors before a fresh connection is served by the same listener. | `soma_service_socket_SUITE:test_socket_rejects_bad_and_oversized_frames_then_serves` |

## Criterion 8 — daemon service ingress is enabled only by service configuration

| Guarantee | Proof |
| --- | --- |
| Normal daemon startup always exposes the CLI socket and exposes the sibling service socket only when a `[service]` table is present. | `soma_service_socket_SUITE:test_daemon_service_listener_is_config_opt_in_with_sibling_default` |

## Criterion 9 — stale takeover is safe and a lost bind preserves the winner

| Guarantee | Proof |
| --- | --- |
| A listener safely replaces a real stale AF_UNIX path, while a later losing contender leaves the live replacement reachable and unchanged. | `soma_service_socket_SUITE:test_service_socket_stale_takeover_and_lost_bind_preserve_winner` |

## Criterion 10 — shared transport and service execution boundaries are pinned

| Guarantee | Proof |
| --- | --- |
| Both listeners delegate framing and path ownership to the shared helpers, the service socket delegates only to public service APIs, and the existing CLI disconnect-cancellation boundary remains present. | `soma_service_socket_boundary_tests:test_socket_adapters_share_transport_and_service_keeps_runtime_boundary` |

## Criterion 11 — the compatibility matrix is complete and machine checked

| Guarantee | Proof |
| --- | --- |
| The published matrix defines version evolution, request and response field rules, typed lifecycle values, cursor semantics, numeric limits, and the support and deprecation policy while matching production constants. | `soma_service_contract_doc_tests:test_service_contract_defines_compatibility_matrix` |

## Criterion 12 — this contract maps every criterion to its proof

| Guarantee | Proof |
| --- | --- |
| This document names one proving module and case for every acceptance criterion of issue #246. | `soma_rs1d_contract_doc_tests:test_rs1d_contract_maps_every_criterion_to_proving_case` |
