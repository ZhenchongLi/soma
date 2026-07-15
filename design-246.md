# [cc] RS.1d: Unix-socket service adapter and compatibility contract

## Current state

RS.1a added the public Lisp `(invoke ...)` form and the pure
`soma_service_envelope:normalize/1` boundary. The normalizer accepts only API
version `<<"1">>`. Its unsupported-version diagnostic does not expose the
supported version set.

RS.1b and RS.1c added the permanent `soma_service` worker under
`soma_actor_sup`. It owns request deduplication, policy admission, run monitors,
deadlines, durable recovery, status projection, result presentation, watch
cursors, plus terminal cancellation. An accepted task is owned by this process.
It is not owned by a caller process or socket connection.

The production service API is available only inside the BEAM today.
The five calls are `soma_service:invoke/1`, `status/1`, `result/1`, `watch/3`,
and `cancel/1`. They have no
socket adapter. An upstream process cannot reconnect to those operations after
its Erlang caller or VM connection goes away.

`soma_lfe` already parses `invoke`, `status`, plus `cancel` forms. It has no
request forms for service `result` or `watch`. A valid CLI `run` form also
compiles successfully, so a service listener must reject that compiled shape
instead of treating the service socket as another execution entry.

`soma_lisp:render/1` renders canonical invoke maps, events, CLI result maps,
message envelopes, plus generic values. It has no tagged service reply or
service error form. Passing public service terms through the generic map
renderer would not identify the operation or the negotiated API version.

`soma_cli_server` is the only Unix-socket listener. It owns its own stale-path
probe and deletion code. It also exports local `frame/1` and `unframe/1`
helpers. The live listener relies on `{packet, 4}` and accepts a complete frame
without an application-level byte cap. This leaves no shared bounded frame
owner for a second listener.

The CLI connection handler owns synchronous CLI runs. Its `tcp_closed` branch
sends `cancel` to that run. This is the required CLI cancel-on-disconnect rule.
A service socket must not copy that ownership rule because `soma_service`
already owns accepted work independently of the connection.

`soma_config:load/1` reads only the `[llm]` table. `soma_cli:daemon/1` and
`daemon_foreground/1` start one CLI listener. There is no `[service]` presence
check and no service socket resolver. The existing CLI socket fallback remains
the product default and must not move.

## Approach

### Service wire adapter

Add `soma_service_socket` under `soma_actor`. It is a separate AF_UNIX listener
with one unlinked handler per accepted connection. Each connection carries one
request frame and one response frame. The handler closes the connection after
the response.

The adapter accepts these request forms:

```lisp
(invoke ...)
(status "<task-id>")
(result "<task-id>")
(watch "<task-id>" (limit 20))
(watch "<task-id>" (cursor "<opaque-cursor>") (limit 20))
(cancel "<task-id>")
```

Keep the existing `status` and `cancel` compiler productions. Add pure
`result` and `watch` productions to `soma_lfe`. `watch` requires one positive
integer limit. Its cursor is optional and must be a binary. Reject repeated or
unknown watch fields with fixed diagnostics.

Every payload first enters `soma_lfe:compile/2`. The listener dispatches only
the five compiled service operation shapes. Each accepted shape calls the
matching registered `soma_service` API. Any other compiled shape returns
`invalid_operation`. This includes CLI run, ask, trace, stop, tool-management,
and message shapes. Such a shape never starts work from the listener.

The response then enters `soma_lisp:render/1`. Add two tagged renderer inputs:

```erlang
#{kind => service_reply,
  api_version => <<"1">>,
  operation => invoke | status | result | watch | cancel,
  value => PublicServiceTerm}

#{kind => service_error,
  api_version => <<"1">>,
  code => ErrorCode,
  supported_api_versions => [<<"1">>] %% unsupported version only
}
```

Render them as `(reply ...)` and `(error ...)` forms. A reply carries
The fields appear in the order `api-version`, `operation`, then `value`. An error carries a fixed
typed code. The unsupported-version error also carries
`supported-api-versions`. The `value` field is the public term returned by
`soma_service`. An inline `result` therefore keeps the exact output map. An
artifact descriptor also keeps its exact public map.

Export `soma_service_envelope:supported_api_versions/0` and use it inside
normalization. The socket error projection reads the same function. This keeps
the accepted set and the advertised set under one owner.

Map compiler and service errors through a fixed allowlist. Preserve existing
typed envelope codes and lifecycle error atoms. Collapse reader failures to
`malformed_request`. Collapse a compiled non-service shape to
`invalid_operation`. Do not render rejected source or diagnostic text. Do not
render exception terms or process-local terms. An unknown internal error becomes
the fixed `internal_error` code.

The service handler never monitors a task for connection ownership. It does
not send cancellation when the client closes. Once `invoke/1` returns an
accepted handle, the registered service continues to own the run. Later
connections can use the returned task id for every lifecycle operation.

Keep cancellation synchronous at the adapter. A handler waiting in
`soma_service:cancel/1` waits for the existing service teardown guarantee. If
the caller has gone away, the reply send may fail after cleanup. That failure
does not change the stored cancelled projection.

### Shared bounded frames

Add `soma_socket_frame` as the sole frame-codec module for both socket
listeners. Use a four-byte unsigned big-endian length followed by the Lisp
payload. Set the hard frame cap to 1,048,576 bytes for requests and responses.
Export the cap for tests and documentation checks.

Both listeners use raw binary sockets. `soma_socket_frame:recv/2` reads exactly
four header bytes, checks the declared length before reading the payload, and
then reads that payload across partial TCP deliveries. A declared length above
the cap returns `frame_too_large` without calling the Lisp reader. A short or
closed frame returns a fixed transport result.

`soma_socket_frame:send/2` applies the same cap before writing the prefix and
payload. A service value whose rendered reply exceeds the cap becomes the fixed
`response_too_large` error. That small error is sent as the response. A caller
can request a smaller watch page after this result.

Refactor `soma_cli_server` to call this module for receive plus send. Keep
`soma_cli_server:frame/1` and `unframe/1` as delegating compatibility wrappers
because existing unit tests call them. Do not change the CLI request grammar.
Do not change the response grammar or connection handler dispatch.

After the shared decoder has consumed one complete CLI request, the CLI handler
can still switch the raw socket to `{active, once}`. Its existing
`tcp_closed` branch continues to cancel the handler-owned run. Keep the current
CLI wire suites unchanged so the merge gate exercises this behavior on the
extracted transport.

The service listener maps a malformed Lisp payload to `malformed_request`. It
maps an oversized declared frame to `frame_too_large`. Each handler terminates
after its fixed reply. The listener remains in its accept loop and serves a
fresh connection.

### Shared socket-path arbitration

Add `soma_socket_path` as the sole bind, stale-path, plus owned-unlink module for
both listeners. Each listener asks it to open the configured path and receives
the listening socket plus an ownership token.

Try the bind before removing anything. On an address-in-use result, inspect the
path type and probe it with a short AF_UNIX connection. A successful probe
means a live winner owns the path. Return `address_in_use` without deleting or
replacing it. Preserve regular files and non-socket paths.

If a socket-like path refuses the probe, acquire a transient exclusive sidecar
claim. Probe again while holding that claim. Only the claim owner may remove a
still-refusing socket path and retry the bind. A contender that did not acquire
the claim waits for its owner to finish and then restarts from the bind step.
It will either win the bind or observe the new live server.

Capture the bound socket file identity in the ownership token. Listener
shutdown first closes its listening socket. It deletes the path only when the
current path still has that recorded identity. Release the sidecar claim with
the same regular-file identity check. A failed bind receives no ownership token
and performs no path cleanup.

Move the current CLI stale-path code into this helper. Both listener modules
must delegate probing, stale deletion, plus post-close unlinking to the helper.
The stale replacement test uses a real leftover AF_UNIX path rather than a
regular file.

### Opt-in daemon listener

Extend `soma_config` with a service-table read that does not change
`soma_config:load/1`. Return `disabled` when the file has no `[service]` header.
The presence of an empty `[service]` table enables the listener. An optional
`socket` string overrides its path.

Resolve the CLI socket first. When the service table has no socket override,
resolve the service socket as `service.sock` in the CLI socket's directory.
For a CLI socket `/run/user/1000/soma.sock`, the service path is
`/run/user/1000/service.sock`. A test-supplied CLI path follows the same rule.

Update both production daemon entry paths. Start the runtime and actor service
before accepting service requests. Start the CLI listener on every normal
daemon boot. Start `soma_service_socket` only when the service table is present.
The permanent in-BEAM `soma_service` may remain supervised when the external
listener is disabled.

Track the optional listener for daemon shutdown. Closing the CLI listener on
`soma stop` also closes an enabled service listener through its owned path
token. A service-listener lost bind is bounded startup data. It must not unlink
or stop the live winner.

Do not add a service verb to `bin/soma`. The new socket is an upstream adapter,
not a replacement for the interactive CLI socket. Do not route existing CLI
commands to `soma_service`.

### Compatibility contract and test alignment

Add `docs/service-contract.md`. Put the wire forms and response forms in one
machine-checked compatibility matrix. The version row names `<<"1">>` as the
current supported set. It states that an unsupported request returns that set.

The matrix treats response fields as additive. A client must ignore any unknown
response field. Request envelopes stay closed under v1. An unknown request field
returns `unknown_field` because a server must not silently discard a new budget
or authority field.

List the typed lifecycle states. `accepted` and `running` are nonterminal.
The terminal set is `succeeded`, `failed`, `rejected`, `cancelled`, and
`in_doubt`.
An unknown future status is never success for an older client.

List the fixed transport and service error codes. Include
`malformed_request`, `frame_too_large`, `response_too_large`,
`unsupported_api_version`, `invalid_operation`, `request_id_conflict`,
`not_found`, `not_ready`, `result_unavailable`, `invalid_cursor`,
`invalid_watch`, `not_running`, `artifact_publish_failed`, and
`internal_error`. Point the envelope-validation row at the fixed RS.1a codes.

Document cursor resume as exclusive. The next page starts at the first durable
event after the event represented by the cursor. The cursor is opaque and tied
to the selected task trail. A reconnect sends the cursor to `watch`. It does
not resend `invoke`.

Document these hard or default limits in the size row:

- Frame payload: 1,048,576 bytes in either direction.
- Terminal status summary: 512 deterministic external-term bytes.
- Default inline result: 16,384 deterministic external-term bytes.
- Watch event payload: 16,384 deterministic external-term bytes.
- Default watch page: 100 events.
- Cursor input: 4,096 bytes.
- Scope entry: 255 bytes.

State the support rule in the matrix. Adding a supported version does not
remove an older version. A version must be marked deprecated while it still
works for one complete tagged minor release. Removal happens only in a later
tagged release after that notice. The advertised supported set changes in the
same commit as the matrix and its machine check.

Put all socket process cases in a new
`apps/soma_actor/test/soma_service_socket_SUITE.erl`. Add separate EUnit modules
for the boundary pin, compatibility document, plus RS.1d proof map. Do not edit
the existing CLI wire suites.

## Acceptance criteria → tests

### Criterion 1 — invoke, status, plus inline result work over the real socket

- Call chain: raw AF_UNIX client → `soma_socket_frame:recv/2` →
  `soma_service_socket` → `soma_lfe:compile/2` →
  `soma_service:invoke/1` → `soma_run_sup:start_run/1` → `soma_run` →
  `soma_tool_call` → echo tool → service terminal transition. Later
  framed connections enter `soma_service:status/1` and
  `soma_service:result/1`. Every response enters `soma_lisp:render/1` and
  `soma_socket_frame:send/2`.
- Test entry: a real `gen_tcp` AF_UNIX connection to a production
  `soma_service_socket`. The case sends an allowed echo invoke, parses the
  accepted handle and polls status to `succeeded`. It then reads the exact inline
  step-output map. A trace around `soma_llm_call:start/1` stays empty.
- Code boundary: service dispatch in
  `apps/soma_actor/src/soma_service_socket.erl`, lifecycle form parsing in
  `apps/soma_lfe/src/soma_lfe.erl` and `soma_lfe_parser.erl`, plus service reply
  rendering in `apps/soma_event_store/src/soma_lisp.erl`.
- Responsibility owner: `soma_service_socket` owns transport adaptation.
  `soma_service` keeps task ownership. The runtime keeps tool execution.
- Test: `test_socket_invoke_status_and_result_end_to_end` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 2 — disconnect does not cancel accepted service work

- Call chain: framed invoke → accepted task owned by `soma_service` → client
  close → connection handler exit → unchanged service-owned run → normal
  terminal message → status on a new connection.
- Test entry: a real service-socket client invokes a slow production tool,
  receives the accepted handle and closes. A new connection polls that task
  until its normal `succeeded` projection appears. The event trail contains
  `run.completed` and no disconnect-driven `run.cancelled`.
- Code boundary: connection teardown in
  `apps/soma_actor/src/soma_service_socket.erl`.
- Responsibility owner: `soma_service` owns accepted work after the invoke
  call. The service connection handler owns no cancellation authority.
- Test: `test_socket_disconnect_does_not_cancel_accepted_invocation` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 3 — duplicate invoke on a new connection reuses one run

- Call chain: first socket invoke → service normalization and durable dedupe
  insert → one run start. A second connection sends the same source → the
  same normalized digest → existing request entry → original handle or
  terminal projection.
- Test entry: two separate real service-socket connections send byte-identical
  invoke frames with one request id. The case compares task ids and counts the
  task's durable `run.started` events.
- Code boundary: socket request projection in
  `apps/soma_actor/src/soma_service_socket.erl`. Existing dedupe remains in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service` is the serialized request-id authority.
  The socket adapter never keeps its own dedupe table.
- Test: `test_socket_duplicate_invoke_reuses_task_once` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 4 — watch reconnect resumes after its opaque cursor

- Call chain: framed watch → `soma_lfe` watch production →
  `soma_service:watch/3` → task correlation lookup → durable append-ordered
  events → `soma_service_watch:page/4` → rendered page and cursor. A new
  connection repeats the chain with that cursor.
- Test entry: a disk-backed production service task followed by two real
  watch connections. The first requests a partial page. The second sends the
  returned cursor. The case compares both pages with the event store's durable
  append order and checks that the resumed page begins after the first page's
  last event id.
- Code boundary: watch parsing in `apps/soma_lfe/src/soma_lfe_parser.erl` and
  watch dispatch in `apps/soma_actor/src/soma_service_socket.erl`.
- Responsibility owner: `soma_service_watch` owns cursor meaning.
  `soma_event_store` owns durable append order. The adapter preserves both.
- Test: `test_socket_watch_reconnect_resumes_after_cursor` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 5 — repeated socket cancellation preserves the cleaned terminal task

- Call chain: framed cancel → `soma_lfe` cancel production →
  `soma_service:cancel/1` → `soma_run` cancellation → CLI worker and external
  process teardown → service cancelled projection → rendered reply. A later
  connection reads the stored cancelled projection through the same call.
- Test entry: a real service-socket invocation of a generated CLI stub that
  records its OS pid. The first cancel response arrives after that process and
  its BEAM worker are gone. A second connection sends the same cancel and gets
  the same decoded projection without increasing the durable event count.
- Code boundary: cancel dispatch and reply shaping in
  `apps/soma_actor/src/soma_service_socket.erl`. Existing deferred cleanup
  remains in `apps/soma_actor/src/soma_service.erl` and `soma_run`.
- Responsibility owner: `soma_service` decides when cancellation is public.
  The socket handler waits for that decision and adds no earlier acknowledgement.
- Test: `test_socket_cancel_is_repeatable_after_cli_process_exit` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 6 — version and operation errors are typed over the socket

- Call chain: framed source → bounded decoder → `soma_lfe:compile/2` →
  service-operation dispatch → `soma_service:invoke/1` → envelope
  normalization. Both errors enter `soma_lisp:render/1`.
- Test entry: one table-driven case over real socket connections. One row sends
  API version `"2"` and expects `unsupported_api_version` plus exactly
  `["1"]`. The other sends an invoke with no tool or steps operation and
  expects `invalid_operation`. Each reply stays below the frame cap. Neither
  row creates `run.started`.
- Code boundary: supported-version ownership in
  `apps/soma_actor/src/soma_service_envelope.erl`, plus dispatch and fixed error
  projection in `apps/soma_actor/src/soma_service_socket.erl`.
- Responsibility owner: `soma_service_envelope` owns the supported API set.
  It also owns canonical operation validation. `soma_service_socket` owns the
  transport error shape.
- Test: `test_socket_version_and_operation_errors_are_typed` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 7 — malformed and oversized frames do not kill the listener

- Call chain: real client → `soma_socket_frame:recv/2`. An in-cap malformed
  payload continues to `soma_lfe:compile/2` and becomes `malformed_request`.
  An oversized header becomes `frame_too_large` before payload parsing. Each
  fixed error enters the shared sender. The listener returns to accept.
- Test entry: one table-driven case sends a malformed Lisp payload and a frame
  declared one byte above `soma_socket_frame:max_bytes/0`. After each error, a
  fresh connection sends a valid unknown-task status request and receives the
  typed `not_found` response from the same listener pid.
- Code boundary: bounded receive and send in
  `apps/soma_actor/src/soma_socket_frame.erl`, plus transport error handling in
  `apps/soma_actor/src/soma_service_socket.erl`.
- Responsibility owner: `soma_socket_frame` owns byte bounds and partial-frame
  reads. `soma_service_socket` owns fixed Lisp error replies and handler isolation.
- Test: `test_socket_rejects_bad_and_oversized_frames_then_serves` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 8 — daemon service ingress is enabled only by `[service]`

- Call chain: `soma_cli:daemon/1` or `daemon_foreground/1` → config load →
  CLI socket resolution → service-table presence decision → optional
  `soma_service_socket:start_link/1` on the configured or sibling path.
- Test entry: the production nonblocking daemon entry with two temporary config
  fixtures and a CLI socket named `soma.sock` in a temporary directory. The
  absent-table row proves only the CLI path answers. The empty-table row proves
  both paths answer and that the service path is the sibling `service.sock`.
- Code boundary: service-table parsing in
  `apps/soma_actor/src/soma_config.erl`, daemon startup in
  `apps/soma_actor/src/soma_cli.erl`. Sibling resolution lives in
  `apps/soma_actor/src/soma_socket_path.erl`.
- Responsibility owner: the daemon owns external listener enablement.
  Configuration presence is the sole default-on decision for service ingress.
- Test: `test_daemon_service_listener_is_config_opt_in_with_sibling_default` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 9 — stale takeover is safe and a lost bind preserves the winner

- Call chain: service listener start → `soma_socket_path` bind attempt →
  socket-type check → live probe → exclusive stale claim → second probe
  → owned stale unlink → bind and identity token. A later contender enters
  the bind and live-probe branch and returns without cleanup authority.
- Test entry: real service listeners on one temporary AF_UNIX path. The case
  kills the first listener to leave a real stale socket, starts a replacement,
  then attempts a third listener on the live path. A fresh client receives a
  typed status response from the replacement after the loser returns.
- Code boundary: arbitration, ownership tokens, plus cleanup in
  `apps/soma_actor/src/soma_socket_path.erl`. Listener startup and shutdown in
  `apps/soma_actor/src/soma_service_socket.erl` use only that API.
- Responsibility owner: `soma_socket_path` is the sole authority allowed to
  remove a socket path. A listener owns only the identity token it receives.
- Test: `test_service_socket_stale_takeover_and_lost_bind_preserve_winner` in
  `apps/soma_actor/test/soma_service_socket_SUITE.erl`.

### Criterion 10 — shared transport and service execution boundaries are pinned

- Call chain: none (compile-time assertion).
- Test entry: EUnit inspects BEAM imports and the named production sources. It
  proves both listeners import `soma_socket_frame` and `soma_socket_path`. It
  proves frame-prefix logic exists only in the codec and stale unlink logic
  exists only in the path helper. It proves `soma_service_socket` imports
  `soma_lfe` plus every public `soma_service` operation. It also imports
  `soma_lisp`. The test rejects
  imports of `soma_run`, `soma_run_sup`, `soma_tool_call`, and
  `soma_llm_call`. It also pins the CLI handler's `tcp_closed` cancellation
  branch and the existing disconnect proof name without changing that suite.
- Code boundary: `apps/soma_actor/src/soma_socket_frame.erl`,
  `soma_socket_path.erl` and `soma_service_socket.erl`. The boundary also covers
  the transport calls in
  `soma_cli_server.erl`. Existing CLI test modules are outside the modifiable
  boundary.
- Responsibility owner: the shared helpers own transport mechanics.
  `soma_service_socket` owns adaptation only. `soma_service` and the runtime
  retain execution ownership.
- Test: `test_socket_adapters_share_transport_and_service_keeps_runtime_boundary`
  in `apps/soma_actor/test/soma_service_socket_boundary_tests.erl`.

### Criterion 11 — the compatibility matrix is complete and machine checked

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/service-contract.md`. It checks the matrix rows
  for version negotiation plus request and response additive-field rules. It
  also checks typed errors, typed statuses, cursor resume, every numeric size limit, plus the
  support and deprecation rule. It compares the documented frame value with
  `soma_socket_frame:max_bytes/0` and the supported set with
  `soma_service_envelope:supported_api_versions/0`.
- Code boundary: `docs/service-contract.md` and
  `apps/soma_actor/test/soma_service_contract_doc_tests.erl`.
- Responsibility owner: `docs/service-contract.md` owns the published
  upstream compatibility promise. Production exports prevent its two central
  constants from drifting.
- Test: `test_service_contract_defines_compatibility_matrix` in
  `apps/soma_actor/test/soma_service_contract_doc_tests.erl`.

### Criterion 12 — the RS.1d contract maps every criterion to one proof

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/contracts/RS.1d-test-contract.md` and checks one
  criterion heading plus one full module-function proof name for all twelve
  issue criteria.
- Code boundary: `docs/contracts/RS.1d-test-contract.md` and
  `apps/soma_actor/test/soma_rs1d_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the durable guarantee-to-proof
  map for RS.1d.
- Test: `test_rs1d_contract_maps_every_criterion_to_proving_case` in
  `apps/soma_actor/test/soma_rs1d_contract_doc_tests.erl`.

## Risks & trade-offs

- Replacing listener-side `{packet, 4}` with a raw bounded reader changes mature
  CLI transport internals. Partial header reads and the transition to active
  mode can introduce disconnect races. The unchanged CLI Common Test suites
  are the regression gate for those details.
- The 1 MiB cap rejects CLI requests that were previously limited only by the
  transport. It bounds memory before Lisp parsing. Large task inputs must use
  artifact references or a later bounded input mechanism.
- A rendered watch page can exceed the frame cap even when each event payload
  passed its own cap. The adapter returns `response_too_large`. The caller must
  retry with a smaller event limit.
- One request per connection makes the handler lifecycle simple and matches
  current CLI behavior. A high-rate upstream caller pays an AF_UNIX connection
  setup cost for each status or watch page.
- A transient sidecar claim closes the stale-delete race between cooperating
  Soma daemons. A process killed during the short claim window can leave a
  sidecar behind. Startup should fail closed on an unowned claim rather than
  delete it without proof.
- A default CLI fallback directly under `/tmp` puts its sibling service socket
  at `/tmp/service.sock`. A configured per-user runtime directory avoids this
  shared basename. Live probing and ownership checks prevent a later Soma
  listener from replacing an existing server.
- Enabling ingress by table presence makes an empty `[service]` table
  operational. Removing the table is the clear way to turn the listener off.
- The tagged reply wrapper adds fields around existing public service terms.
  Clients must read the documented `value` field and ignore future additive
  response fields. The wrapped task or result term itself stays unchanged.
- The service socket exposes only the current single-user local trust boundary.
  Filesystem permissions still determine who can connect. Authentication and
  task-scoped product authorization remain outside this issue.
