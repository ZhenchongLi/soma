# Soma service compatibility contract

This document is the compatibility promise for upstream programs that use the
local Soma service socket. The socket carries one length-prefixed Soma Lisp
request and one Soma Lisp response per AF_UNIX connection. The four-byte prefix
is the unsigned big-endian payload length; it is not part of the payload limit.

The matrix below is normative and machine checked. Names such as
`unsupported_api_version` use their canonical Erlang spelling in the matrix;
Soma Lisp renders atom underscores as hyphens, so that code appears as
`unsupported-api-version` on the wire.

## Compatibility matrix

| Area | Version 1 contract |
| --- | --- |
| Version negotiation | The API version is `<<"1">>` and the current supported set is `[<<"1">>]`. An unsupported request returns `unsupported_api_version` and advertises that exact set in `supported-api-versions`. |
| Request forms | v1 accepts `(invoke ...)`, `(status "<task-id>")`, `(result "<task-id>")`, `(watch "<task-id>" (limit 20))`, `(watch "<task-id>" (cursor "<opaque-cursor>") (limit 20))`, and `(cancel "<task-id>")`. A compiled shape outside those service operations returns `invalid_operation` and starts no work. A watch limit is one positive integer; its cursor is an optional binary. |
| Response forms | Success is `(reply (api-version "1") (operation <operation>) (value <public-service-term>))`; the fields stay ordered as `api-version`, `operation`, then `value`. Failure is `(error (api-version "1") (code <typed-code>))`. Only `unsupported_api_version` adds `(supported-api-versions ("1"))`. The value is the exact public service term, including an inline result or artifact descriptor. |
| Request fields | Request envelopes are closed under v1. An unknown request field returns `unknown_field`; a v1 server must not silently discard a new budget, scope, authority, or other request field. Repeated fields are also rejected by the fixed envelope-validation boundary. |
| Response fields | Response fields are additive. A client must ignore unknown response fields while continuing to require and interpret the v1 fields it understands. |
| Binary values | A binary that is valid UTF-8 uses the Lisp string form. Any other binary uses the lossless `(bytes (hex "<uppercase hexadecimal>"))` form; clients decode its even-length uppercase hexadecimal payload to recover the exact bytes. This applies to both inline results and an artifact descriptor's `truncated_inline` value. |
| Typed statuses | `accepted` and `running` are nonterminal. The terminal set is `succeeded`, `failed`, `rejected`, `cancelled`, and `in_doubt`. An unknown future status is never success for an older client. |
| Typed errors | The fixed transport and service codes are `malformed_request`, `frame_too_large`, `response_too_large`, `unsupported_api_version`, `invalid_operation`, `request_id_conflict`, `not_found`, `not_ready`, `result_unavailable`, `invalid_cursor`, `invalid_watch`, `not_running`, `artifact_publish_failed`, and `internal_error`. Reader failures collapse to `malformed_request`; unrecognized internal failures collapse to `internal_error`. Invoke validation also uses the [RS.1a fixed envelope-validation codes](contracts/RS.1a-test-contract.md). |
| Envelope validation errors | The RS.1a fixed set is `missing_api_version`, `unsupported_api_version`, `missing_request_id`, `invalid_request_id`, `duplicate_field`, `unknown_field`, `invalid_operation`, `invalid_budget`, `scope_entry_too_large`, `invalid_artifacts`, and `invalid_correlation_id`. These diagnostics are bounded and never echo rejected source. |
| Cursor resume | Cursor resume is exclusive: the next page starts at the first durable event after the event represented by the cursor. A cursor is opaque and tied to the selected task trail. On reconnect, the client sends the last cursor to `watch`; it does not resend `invoke`. |
| Size limits | `frame_payload_bytes=1048576` (1,048,576 bytes, hard cap in either direction); `terminal_status_summary_bytes=512` (deterministic external-term bytes); `default_inline_result_bytes=16384` (16,384 deterministic external-term bytes); `watch_event_payload_bytes=16384` (16,384 deterministic external-term bytes); `default_watch_page_events=100`; `cursor_input_bytes=4096` (4,096 bytes); `scope_entry_bytes=255` (255 bytes). A rendered response above the frame cap becomes `response_too_large`; a watch caller can retry with a smaller page. |
| Support and deprecation | Adding a supported version does not remove an older version. A version must be marked deprecated while it still works for one complete tagged minor release. Removal happens only in a later tagged release after that notice. The advertised supported set changes in the same commit as this matrix and its machine check. |

## Connection and ownership rules

The adapter closes the connection after its fixed response. Closing a client
connection does not cancel accepted service work: `soma_service` owns the task,
and a later connection uses its task id with `status`, `result`, `watch`, or
`cancel`. A reconnect that is following events resumes with `watch` and the
last opaque cursor. It never repeats `invoke` merely to resume observation.

Cancellation is synchronous from the adapter's perspective. A cancel reply is
sent only after the service's owned run and external process teardown has
reached the stored cancelled projection. Losing the connection before that
reply does not undo the cancellation.

## Framing failures

The receiver checks the declared frame length before reading or parsing the
payload. A declared length over the hard cap returns `frame_too_large`. A
zero-length frame is a complete empty payload and returns `malformed_request`
without waiting for another byte; any other in-cap payload that is not a valid
request returns the same error. The listener remains available for a fresh
connection after each failure.

The same cap applies when sending. If rendering a normal reply would exceed
it, the adapter sends the bounded `response_too_large` error instead. Clients
should reduce a watch page's requested limit when that error follows `watch`.
