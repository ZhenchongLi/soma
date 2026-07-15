# [cc] RS.1c: status, artifact results, watch cursors, idempotent cancel

## Current state

RS.1b added the permanent `soma_service` process under `soma_actor_sup`. The
service normalizes an invoke envelope, deduplicates it by request id, checks the
existing tool policy, and owns the resulting `soma_run`. It rebuilds tasks from
the durable event trail after restart. It also waits for run cleanup before it
records a terminal task.

The public surface currently contains `invoke/1`, `status/1`, and `cancel/1`.
`status/1` returns `public_task/1`. A successful terminal map contains the whole
step-output map under `result`. A failed terminal map contains the internal
`reason`. The response has no separate bounded summary, so status reads mix
lifecycle data with result delivery.

The service keeps a successful output in its internal task map. Durable
recovery can reconstruct the same output from `step.succeeded` events. There is
no `result/1` read, no inline presentation cap, and no artifact publisher.
`max_output_bytes` is already enforced when a run completes. An output above
that budget fails the task and is not retained as a service result.

The envelope may carry a `correlation_id`. `start_allowed_invocation/5` passes
that value to `soma_run`, and the run stamps it on every run event. A missing
value stays missing. Service lifecycle events do not carry a correlation id.
This means an ordinary service task has no correlation that a watch read can
use.

`soma_event_store:by_correlation/2` already returns matching events in durable
append order. Normalization gives every event an `event_id` and preserves an id
that a producer supplied. The service has no watch API, cursor format, page
limit, or response scrubber. Runtime events may contain a tool worker pid.
Event payloads may also contain complete step inputs and outputs.

`cancel/1` currently records `service.task.cancel_requested`, sends `cancel` to
the run, and immediately returns `ok`. The terminal transition happens later.
A second call after cancellation returns `{error, not_running}`. The existing
run path already kills the tool worker and external process before it sends
`run_cancelled`, and `soma_service:finish_run/3` removes the run child before it
publishes the service terminal event.

The actor application has only `service_policy` in its application defaults.
It has no `service_result_inline_bytes`, `service_data_dir`, or
`service_watch_page_events` settings.

## Approach

Keep this slice in `soma_actor`. Add `result/1` and `watch/3` to
`soma_service`. Do not change `soma_run`, step execution, tool workers, or the
event-store query API.

### Status projection

Separate the internal task record from every public read. The internal record
may continue to hold `result`, `reason`, run ownership fields, timers, and
cancel waiters. None of those fields belong in a terminal status response.

Add one terminal status projection with exactly these keys:

```erlang
#{task_id => TaskId,
  request_id => RequestId,
  status => Status,
  summary => Summary}
```

Use `#{result_bytes => N}` for a successful summary. `N` is the byte size of
`term_to_binary(Output, [deterministic])`. Use
`#{reason_class => ReasonClass}` for every non-success terminal status. A
failed status therefore exposes no raw reason, tuple detail, output, stack, or
process term. Map the service's known reason atoms and known tuple heads to a
fixed class. Fall back to `failed` for an unknown internal shape.

Check the summary with `term_to_binary(Summary, [deterministic])`. The fixed
fallback is class-only, so it always stays at or below 512 bytes. Keep accepted
and running reads as the existing three-key lifecycle maps without a summary.

Use the same terminal projection for a completed duplicate invoke and an
immediate terminal admission result. This keeps dedupe behavior while ensuring
that a duplicate invoke cannot bypass `result/1` and return a large output.
Existing RS.1b tests that read an output or detailed reason from `status/1`
must move that assertion to `result/1` or the durable event trail. Their
ownership and monotonic-lifecycle assertions remain unchanged.

### Inline and artifact results

Add `soma_service:result/1`. It first checks the task table. An unknown task
returns `{error, not_found}`. A succeeded task is passed to a new actor-layer
helper named `soma_service_artifact`. An active task returns a bounded
`{error, not_ready}`. A non-success terminal task returns a bounded
`{error, result_unavailable}`.

Encode the whole step-output map once with
`term_to_binary(Output, [deterministic])`. The default inline cap is 16,384
bytes. A positive `service_result_inline_bytes` application setting replaces
that default. When the encoded size is at or below the cap, return
`{ok, Output}`. Do not create the data directory in this branch.

When the encoded size is above the cap, return this descriptor:

```erlang
#{artifact => ArtifactId,
  bytes => byte_size(Encoded),
  truncated_inline => binary:part(Encoded, 0, InlineCap)}
```

The public call wraps the descriptor in `{ok, Descriptor}`. Derive the opaque
binary artifact id from a version tag, the minted task id, and the complete
encoded output with SHA-256. Render only the digest into the filename. Raw task
ids and result data must not become path components. Including the task id
makes artifact ownership task-scoped. The deterministic derivation also lets a
recovered service find the same artifact without journaling another mutable
index.

Resolve `service_data_dir` at service start. A configured path wins. Otherwise
use `$HOME/.soma/data`. Store published files under an `artifacts` child
directory. The file content is exactly `Encoded`. The descriptor does not
expose the local path.

Publish with a temporary regular file in the destination directory. Give the
temporary name a fresh random suffix. Create it with exclusive-create
semantics. Write all bytes, sync, close, and rename it to the final path. A
successful exclusive create is the ownership capability for rollback. Record
the file identity returned after creation. Before deleting after an error,
check that the path is still the exact generated temp path and that
`file:read_link_info/1` reports the same regular-file identity. Do not scan the
directory for stale-looking names. Do not delete a pre-existing file or
symlink.

Before publishing, read an existing final artifact. Reuse it only when its
bytes equal `Encoded`. Return an error on a mismatched or non-regular target.
Never rewrite a matching final file. This preserves the artifact id, bytes, and
mtime on repeated `result/1` calls. A publication error returns
`{error, artifact_publish_failed}` and leaves the succeeded task available for
a later retry. Do not append an event for an inline read or an artifact read.

Keep `max_output_bytes` where RS.1b enforces it. It remains the hard execution
budget. `service_result_inline_bytes` only chooses how an already-successful
result is presented.

### Correlation and watch pages

Mint the task id before choosing a correlation. Store
`maps:get(correlation_id, Envelope, TaskId)` in the task. Pass that value to
the run in every allowed invocation. Include it on every service lifecycle
event, including `service.task.accepted`. Restore it from the accepted event
during durable service recovery. Older accepted events without the field can
use their task id as the bounded fallback.

Implement `watch(TaskId, Cursor, Limit)` in the service. Check task existence
before reading the cursor. Use the task's stored correlation id with the
existing `soma_event_store:by_correlation/2` call. This keeps durable append
order and does not add a query to the event store.

Return pages in this shape:

```erlang
{ok, #{events => Events, cursor => NextCursor}}
```

`undefined` means the caller has no cursor. A non-empty page returns an opaque
binary cursor for its last original `event_id`. An empty first page returns an
undefined cursor. An empty resumed page returns the supplied cursor so polling
does not lose its position.

Encode a version tag and the last event id with deterministic external-term
encoding, then base64-encode those bytes. Bound the accepted cursor length.
Decode with `binary_to_term(Bytes, [safe])`. A malformed cursor or an event id
that is not present in this task's current correlation trail returns
`{error, invalid_cursor}`. Resume by scanning append-ordered events to the exact
event id and taking the first event after it. Do not compare event ids for
ordering.

Require a positive integer `Limit`. The page size is
`min(Limit, ServiceWatchPageEvents)`. The application setting
`service_watch_page_events` replaces the default of 100.

Put cursor and scrubbing code in an actor-layer helper named
`soma_service_watch`. Sanitize every selected event before returning it. Keep
the original binary `event_id` unchanged. Traverse maps, lists, and tuples.
Drop entries whose key is the atom or binary form of `secret_value` without
walking their value. Replace pid, port, and reference terms with a fixed
`redacted` atom. Apply the same rule to nested terms and map keys. Replace a
standalone `secret_value` sentinel with `redacted` too.

After recursive scrubbing, encode every field named `payload` with
`term_to_binary(Payload, [deterministic])`. If it is larger than 16,384 bytes,
replace it with a fixed bounded marker that includes only `truncated => true`
and the encoded byte count. This is a watch presentation cap. It does not
rewrite or delete the durable event.

### Idempotent cancellation

Change the first `cancel/1` call on a running task into a deferred gen_server
reply. Record one cancel-requested event, cancel the deadline timer, send one
`cancel` message to the run, and retain the caller's `From` value only in live
service state. Do not put callers, pids, or references into task events.

If another cancel call arrives while cleanup is active, add its caller to the
same waiter list. Do not emit another event and do not send another cancel
message. `finish_run/3` already runs after the tool worker and external process
have stopped. Keep its run-child termination before the public transition.
After it stores the cancelled task and appends the one terminal event, reply to
all waiters with `{ok, TerminalStatus}`.

A later cancel of a stored cancelled task returns the same
`{ok, TerminalStatus}` immediately. It appends no event. Other terminal states
may retain the bounded `{error, not_running}` reply. An unknown task retains
`{error, not_found}`.

### Configuration and test alignment

Add the numeric defaults to `apps/soma_actor/src/soma_actor.app.src`. Resolve
the HOME-based data directory in service initialization because application
metadata cannot expand `$HOME`. Keep all three values in service state so one
service lifetime uses one configuration snapshot.

Extend `soma_service_SUITE` for the public process behavior. Add a small EUnit
module for the artifact rollback seam. That module can inject a rename failure
after the real exclusive temp create and write. The injected operation must
still use the production ownership check and cleanup code.

Add `docs/contracts/RS.1c-test-contract.md` and its source-reading EUnit proof.
The contract has one section for each of the ten criteria below.

## Acceptance criteria → tests

### Criterion 1 — terminal status is summary-only and bounded

- Call chain: `soma_service:invoke/1` → normalization and admission →
  `soma_run` → terminal service task → `soma_service:status/1` →
  terminal status projection → bounded summary.
- Test entry: `soma_service:invoke/1` for one production echo task and one
  production fail task, followed by public `status/1` reads. No service or
  runtime layer is bypassed.
- Code boundary: terminal task projection and reason classification in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service` owns the public lifecycle view. The
  internal task record remains private.
- Test: `test_terminal_status_has_bounded_summary_only` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 2 — small results stay inline under the configured cap

- Call chain: service invoke → production echo run and tool worker → stored
  successful output → `soma_service:result/1` → deterministic encoding →
  inline selection.
- Test entry: table-driven public invokes and `result/1` reads. One row uses
  the 16,384-byte default. One row restarts the service with a smaller positive
  `service_result_inline_bytes` value. Each row checks that no artifact file or
  directory appears.
- Code boundary: result dispatch and configuration in
  `apps/soma_actor/src/soma_service.erl`, artifact selection in
  `apps/soma_actor/src/soma_service_artifact.erl`, and defaults in
  `apps/soma_actor/src/soma_actor.app.src`.
- Responsibility owner: `soma_service_artifact` owns deterministic size
  calculation and inline selection. `soma_service` owns task lookup.
- Test: `test_result_inline_uses_default_and_configured_cap` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 3 — an oversized result publishes one stable complete artifact

- Call chain: service invoke → successful output → public `result/1` →
  deterministic encoding → task-scoped artifact id → exclusive temp write
  → final rename → artifact descriptor.
- Test entry: production echo through `soma_service:invoke/1`, followed by two
  public `result/1` calls with a small configured inline cap and a temporary
  `service_data_dir`. The case reads the published file and its file info.
- Code boundary: result lookup in `apps/soma_actor/src/soma_service.erl` and
  publication in `apps/soma_actor/src/soma_service_artifact.erl`.
- Responsibility owner: `soma_service_artifact` owns the encoded bytes,
  artifact identity, atomic publication, and no-rewrite reuse rule.
- Test: `test_oversized_result_publishes_stable_artifact` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 4 — failed publication removes only its owned temporary file

- Call chain: public result presentation → `soma_service_artifact` publication
  → exclusive temp ownership → injected rename error → ownership check →
  rollback delete.
- Test entry: `soma_service_artifact` at its publication function. This starts
  below `result/1` because a full public call cannot reliably force a failure
  after temp creation without a filesystem race. The case injects only the
  final rename error. It uses the real temp create, write, ownership check, and
  delete path.
- Code boundary: the bounded file-operation seam and rollback logic in
  `apps/soma_actor/src/soma_service_artifact.erl`.
- Responsibility owner: `soma_service_artifact` owns every temporary file it
  creates and must prove that ownership before cleanup.
- Test: `test_failed_publication_cleans_only_owned_temp` in
  `apps/soma_actor/test/soma_service_artifact_tests.erl`.

### Criterion 5 — missing correlation defaults to task id and watch keeps append order

- Call chain: `soma_service:invoke/1` without correlation → task-id minting →
  default correlation → correlated service and run events →
  `soma_service:watch/3` → `soma_event_store:by_correlation/2` → scrubbed
  watch page.
- Test entry: production echo through the public service, followed by
  `watch(TaskId, undefined, Limit)`. The case compares returned event ids with
  the direct durable correlation trail in append order.
- Code boundary: correlation selection, lifecycle emission, recovery, and
  watch dispatch in `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service` owns a correlation for every service
  task. `soma_event_store` remains the append-order source of truth.
- Test: `test_missing_correlation_defaults_to_task_watch_order` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 6 — opaque cursors resume after the last event and pages are clamped

- Call chain: public watch → task correlation lookup → append-ordered events
  → cursor decode and exact event-id split →
  `min(Limit, service_watch_page_events)` → cursor for the page's last event.
- Test entry: repeated `soma_service:watch/3` calls for one completed task. The
  first call requests more than a small configured page cap. The second feeds
  back the returned binary cursor. A third page uses a caller limit below the
  configured cap.
- Code boundary: cursor codec and page slicing in
  `apps/soma_actor/src/soma_service_watch.erl`, plus configuration lookup in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service_watch` owns cursor validation and page
  boundaries. Event ordering remains owned by `soma_event_store`.
- Test: `test_watch_cursor_resumes_and_page_limit_is_clamped` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 7 — watch recursively removes unsafe terms and oversized payloads

- Call chain: public watch → correlation query → selected durable event →
  recursive term scrub → deterministic payload-size check → bounded page.
- Test entry: `soma_service:watch/3` after the fixture appends one controlled
  event under a real service task's correlation. Direct append is used because
  the public invoke grammar cannot create a port or reference. The watch query
  and complete production scrub path are not bypassed.
- Code boundary: recursive scrub and payload cap in
  `apps/soma_actor/src/soma_service_watch.erl`.
- Responsibility owner: `soma_service_watch` owns safe external event
  presentation. The durable event store keeps the original event unchanged.
- Test: `test_watch_recursively_scrubs_secrets_runtime_terms_and_large_payloads`
  in `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 8 — cancellation replies after teardown and is idempotent

- Call chain: `soma_service:cancel/1` → one cancel-requested transition →
  `soma_run` cancel → tool worker and external process teardown →
  `run_cancelled` → run-child removal → service terminal event → deferred
  cancel reply. A repeated call reads the stored terminal projection.
- Test entry: a public service invoke using the existing sleeping CLI stub,
  followed by two public cancel calls. The case observes the run child, worker,
  and OS pid. It counts durable correlation events after each reply.
- Code boundary: cancel waiter state, terminal transition, and idempotent
  terminal branch in `apps/soma_actor/src/soma_service.erl`. Existing resource
  teardown remains in `apps/soma_runtime/src/soma_run.erl`.
- Responsibility owner: `soma_service` owns when the public cancel completes.
  `soma_run` owns teardown of the invocation resources.
- Test: `test_cancel_is_terminal_and_idempotent_after_teardown` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 9 — result and watch return typed not-found errors

- Call chain: `soma_service:result/1` or `soma_service:watch/3` → service task
  table lookup → `{error, not_found}`.
- Test entry: one table-driven case calls both public functions with the same
  unknown binary task id. No internal helper is called directly.
- Code boundary: public call handlers in
  `apps/soma_actor/src/soma_service.erl`.
- Responsibility owner: `soma_service` owns the durable task-id namespace and
  its typed miss response.
- Test: `test_result_and_watch_unknown_task_are_not_found` in
  `apps/soma_actor/test/soma_service_SUITE.erl`.

### Criterion 10 — the RS.1c contract maps every criterion to its proof

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/contracts/RS.1c-test-contract.md` and checks one
  heading and one full module-function proof name for all ten criteria.
- Code boundary: `docs/contracts/RS.1c-test-contract.md` and
  `apps/soma_actor/test/soma_rs1c_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the durable guarantee-to-proof
  map for RS.1c.
- Test: `test_rs1c_contract_maps_every_criterion_to_proving_case` in
  `apps/soma_actor/test/soma_rs1c_contract_doc_tests.erl`.

## Risks & trade-offs

- Deterministic result encoding allocates the complete encoded output for an
  artifact. This is required for the exact file and prefix contract. The
  existing `max_output_bytes` budget remains the caller's hard bound when it is
  configured.
- Artifact publication performs filesystem work while serving a result read.
  The registered service serializes those calls, which simplifies idempotency
  but can delay unrelated service reads during a large write. A separate
  publisher worker would add monitor and waiter recovery work that this slice
  does not require.
- A SHA-256 collision between task-scoped artifact identities is theoretically
  possible. The existing-file byte comparison prevents silent reuse when the
  final content differs.
- The final rename and the existing-file check cannot make an untrusted shared
  directory safe against every external replacement race. The default path is
  per-user data. Exclusive temp creation and ownership-checked rollback ensure
  Soma deletes only a temp it created.
- Watch reads scan the complete correlation trail before slicing a page. This
  preserves the unchanged event-store query boundary. Its cost grows with the
  durable log until the separate index and compaction work lands.
- A caller-supplied correlation id may be shared by several tasks. Watching
  one of those tasks intentionally returns the whole correlation chain, not
  only events whose `task_id` matches the lookup key.
- Scrubbing removes process-debugging detail and replaces large payloads with a
  marker. Operators can still use the internal event store and existing trace
  tools when they are inside the trusted runtime boundary.
- Deferring the first cancel reply makes cancellation latency equal real
  teardown latency. This is the intended public guarantee. A defect in a lower
  cleanup path will now be visible as a blocked cancel instead of an early
  `ok`.
- Moving output and detailed failures out of terminal status changes old
  service read expectations. The repository's RS.1b process tests must use
  `result/1` and event assertions where they previously inspected those fields.
  The socket adapter remains deferred to RS.1d.
