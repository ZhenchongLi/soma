# CLI.3: soma status + trace — read commands over the Lisp wire

## Current state

The `soma` daemon already answers two write commands over the local Unix socket,
both Lisp-only. `soma_cli_server:handle_lisp_request/3` compiles the framed bytes
with `soma_lfe:compile/2`, branches on `{ok, #{run := ...}}` or `{ok, #{ask := ...}}`,
runs it, and renders a `(result ...)` reply with `soma_lisp:render/1`. The client
side is `soma_cli:run/1` and `soma_cli:ask/1` — connect, frame+send, read, print,
return an exit code.

There are no read commands. A client that runs a workflow gets back a result with a
correlation id, but it cannot ask the daemon to render that run's event chain, and it
cannot ask for a task's terminal status by id. The pieces a read path needs already
exist, just not wired to the wire:

- `soma_event_store:by_correlation/2` returns every event stamped with a correlation
  id. `soma_trace:render_lisp/2` already fetches that chain, sorts it by timestamp
  ascending, and renders one `(event ...)` s-expr per event. It is tested by
  `soma_trace_lisp_SUITE` but nothing on the wire calls it.
- `soma_event_store:by_session/2` returns every event for a session id. The run path
  in `soma_cli_server:run_steps/2` sets `session_id => TaskId`, so a task's events are
  reachable by its task id through `by_session/2` even though there is no `by_task`
  query.

Two gaps block the read commands beyond just adding handlers:

- `soma_lfe:compile/2` has no `(trace ...)` or `(status ...)` form. `dispatch/1` in
  `soma_lfe.erl` routes `msg` / `reply` / `run-steps` / `ask`, and everything else
  falls through to `parse_run/1`, which rejects a non-`run` head.
- `soma_lisp:result_pairs/1` drops `task_id`. It renders only `status`, `outputs`,
  `error`, and `correlation-id`. So a client that runs `soma run` gets back no task id
  to feed into `soma status`. `docs/cli.md` already claims the `(result ...)` form
  carries `(task-id ...)`, so the doc and the renderer disagree today.

## Approach

Add the two read commands by extending the same four seams the write commands use:
the parser, the renderer, the server handler, and the client.

**Parser.** Add `parse_trace/1` and `parse_status/1` to `soma_lfe_parser`, and route
`(trace ...)` and `(status ...)` heads in `soma_lfe:dispatch/1`. Each takes one quoted
string and returns a command map with a distinct top-level key, so the server can tell
the three read/write results apart by key alone:

- `(trace "c-1")` → `{ok, #{trace => #{correlation_id => <<"c-1">>}}}`
- `(status "t-1")` → `{ok, #{status => #{task_id => <<"t-1">>}}}`

These keys (`trace`, `status`) are distinct from the write path's `run` and `ask`
keys, which is what the first two criteria assert. A `(trace ...)` / `(status ...)`
with no string, or a non-string argument, returns a diagnostic, the same shape the ask
parser returns for a bad intent. This keeps the malformed-request path on the existing
error rendering, never a parser crash.

**Renderer.** Add `task_id` to `soma_lisp:result_pairs/1`. It renders as a
`(task-id ...)` sub-form inside `(result ...)`. Place it after `status` and before
`correlation-id` so the existing completed-result order stays stable for the run and
ask cases that already assert on it. The existing `soma_lisp_tests` result test uses a
map with no `task_id`, so it is unaffected — adding a key the map does not carry
changes nothing.

The run and ask result maps in `soma_cli_server` already carry `task_id`. Once the
renderer emits it, a `soma run` reply carries the task id a client feeds to
`soma status`, with no change to the server's result shapes.

**Server handler.** `handle_lisp_request/3` gains two branches:

- `{ok, #{trace := #{correlation_id := CorrId}}}` → render the chain. The reply is a
  single `(trace ...)` s-expr whose sub-forms are that correlation's events in
  timestamp order. `soma_trace:render_lisp/2` already produces the ordered event
  s-exprs; the trace handler wraps them in a `(trace ...)` head. The ending event is
  the chain's last by timestamp, which for a completed run is `run.completed`.
- `{ok, #{status := #{task_id := TaskId}}}` → look the task up and render a
  `(status ...)` s-expr. The lookup uses `by_session(Store, TaskId)` because the run
  path sets `session_id => TaskId`. The reported `(state ...)` is derived from the
  task's events: if the chain carries a `run.completed` event the state is `completed`;
  a `run.failed` / `run.timeout` / `run.cancelled` event maps to that terminal state;
  an empty chain (no events for that id) is `unknown`. An unknown id returns
  `(status (state unknown) ...)` and does not crash the handler, so the server stays up
  for the next connection.

Both read handlers are read-only against the event store. They run no `soma_run` and
start no actor, so neither touches the run or ask paths.

**Client.** Add `soma_cli:trace/1` and `soma_cli:status/1`. Each builds its one-line
s-expr source client-side (`(trace "...")` / `(status "...")`), drives the same
connect / frame+send / read / print path as `run/1` and `ask/1`, and returns exit 0.
The read commands always print a reply and exit 0 — unlike `run`/`ask`, a successful
read is not gated on `(status completed)`; the exit-0 criterion is about the read
succeeding, not about what state it reports.

**Why no `by_task` query.** The store has no `by_task`, and this slice does not add
one. The run path already aliases `session_id` to the task id, so `by_session/2`
reaches a task's events without a new query. Adding `by_task` would be a wider store
change than the criteria call for, and the status criteria only assert the reported
`(state ...)`.

**Why cancel and --detach are out.** A synchronous `run`/`ask` task is already terminal
by the time the client holds its id — there is no live task to cancel by id. A real
`soma cancel <id>` needs a fire-and-forget task model and a live-task registry, which
is a separate slice. `docs/cli.md` records the deferral.

## Acceptance criteria → tests

### Criterion 1 — `(trace "c-1")` compiles to a distinct trace command
- Call chain: `none (pure compile boundary)` — `soma_lfe:compile/2` is a pure
  function the test calls directly.
- Test entry: `soma_lfe:compile/2`.
- Test: `test_trace_compiles_to_trace_command` in
  `apps/soma_lfe/test/soma_lfe_read_tests.erl`

### Criterion 2 — `(status "t-1")` compiles to a distinct status command
- Call chain: `none (pure compile boundary)` — `soma_lfe:compile/2` called directly.
- Test entry: `soma_lfe:compile/2`.
- Test: `test_status_compiles_to_status_command` in
  `apps/soma_lfe/test/soma_lfe_read_tests.erl`

### Criterion 3 — a result map with `task_id` renders a `(task-id ...)` sub-form
- Call chain: `none (pure renderer)` — `soma_lisp:render/1` called directly on a
  result map carrying `task_id`.
- Test entry: `soma_lisp:render/1`.
- Test: `test_render_result_map_with_task_id_emits_task_id_subform` in
  `apps/soma_event_store/test/soma_lisp_tests.erl`

### Criterion 4 — a completed run's `(trace ...)` reply carries its events in order, ending with `run.completed`
- Call chain: client `(run ...)` over the temp socket → `soma_cli_server` handle →
  `soma_lfe:compile/2` → `soma_run` → `run.completed` recorded → client reads the run's
  correlation id off the `(result ...)` reply → client sends `(trace "<corr>")` →
  server handle → `soma_lfe:compile/2` → `soma_trace:render_lisp/2` →
  `by_correlation/2` → `soma_lisp:render/1` per event → framed `(trace ...)` reply.
- Test entry: a real `gen_tcp` client over the temp Unix socket (no layer bypassed —
  the run runs first, then the trace request reads back its real correlation chain).
- Test: `test_trace_after_run_returns_ordered_chain_ending_completed` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 5 — a completed run's `(status ...)` reply reports `(state completed)`
- Call chain: client `(run ...)` over the temp socket → `soma_cli_server` handle → run
  completes → client reads the task id off the `(result ...)` reply → client sends
  `(status "<task>")` → server handle → `soma_lfe:compile/2` → `by_session/2` → state
  derived from events → `soma_lisp:render/1` → framed `(status ...)` reply.
- Test entry: a real `gen_tcp` client over the temp Unix socket (no layer bypassed).
- Test: `test_status_after_run_reports_state_completed` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 6 — `(status "no-such-id")` reports `(state unknown)` and the server stays up
- Call chain: client sends `(status "no-such-id")` over the temp socket → server
  handle → `soma_lfe:compile/2` → `by_session/2` returns `[]` → state `unknown` →
  framed `(status (state unknown) ...)` reply; then a fresh connection sends an echo
  `(run ...)` and gets a `completed` reply.
- Test entry: a real `gen_tcp` client over the temp Unix socket (no layer bypassed).
- Test: `test_status_unknown_id_reports_unknown_and_server_survives` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 7 — `soma_cli:trace/1` prints the `(trace ...)` reply and exits 0
- Call chain: `soma_cli:trace/1` → connect to temp socket → frame+send `(trace ...)` →
  `soma_cli_server` handle → `soma_trace:render_lisp/2` → framed reply → client prints
  → exit 0. The test seeds a correlation chain first by running a `(run ...)` and
  reading its correlation id off the result.
- Test entry: `soma_cli:trace/1` (the client entry, driven against a real server).
- Test: `test_trace_prints_reply_exit_zero` in
  `apps/soma_actor/test/soma_cli_SUITE.erl`

### Criterion 8 — `soma_cli:status/1` prints the `(status ...)` reply and exits 0
- Call chain: `soma_cli:status/1` → connect to temp socket → frame+send `(status ...)`
  → `soma_cli_server` handle → `by_session/2` → framed reply → client prints → exit 0.
  The test seeds a task first by running a `(run ...)` and reading its task id off the
  result.
- Test entry: `soma_cli:status/1` (the client entry, driven against a real server).
- Test: `test_status_prints_reply_exit_zero` in
  `apps/soma_actor/test/soma_cli_SUITE.erl`

### Criterion 9 — `docs/cli.md` documents status + trace over the wire and records the deferral
- Call chain: `none (docs deliverable, pinned by a source-read test)`.
- Test entry: a source-read test that asserts `docs/cli.md` documents the `(trace ...)`
  and `(status ...)` requests and their replies, and records that `soma cancel <id>`
  and `--detach` are deferred.
- Test: `test_cli_md_documents_status_trace_and_defers_cancel_detach` in
  `apps/soma_actor/test/soma_cli_md_read_tests.erl`

### Criterion 10 — `docs/contracts/` has a CLI.3 contract mapping each proof to a case
- Call chain: `none (docs deliverable, pinned by a source-read test)`.
- Test entry: a source-read test that asserts `docs/contracts/cli-3-test-contract.md`
  exists, is non-empty, and names every CLI.3 suite/module and each of its case names.
- Test: `test_doc_names_cli_3_suites_and_cases` in
  `apps/soma_actor/test/soma_cli_3_contract_tests.erl`

### Criterion 11 — the gate is green and opens no real LLM or network socket
- Call chain: `none (source-scan assertion)` — a marker scan of the CLI.3 test sources,
  same shape as `soma_cli_2_marker_tests`.
- Test entry: a source-read test that scans the CLI.3 test files for real-provider
  markers and non-`{local, _}` sockets.
- Test: `test_cli_3_sources_have_no_real_provider_or_socket_marker` in
  `apps/soma_actor/test/soma_cli_3_marker_tests.erl`

### Criterion 12 — dialyzer is run and its result reported
- Call chain: `none (build step, reported in the PR)`.
- Test entry: `rebar3 dialyzer` run by hand; its result goes in the PR body. There is
  no test function — the project does not gate dialyzer (baseline 4 warnings).
- Test: none (PR report)

## Risks & trade-offs

- **Status by `by_session/2` leans on the run path aliasing `session_id` to the task
  id.** This is a real coupling: if a future change stops setting `session_id =>
  TaskId` on the run, status lookup silently returns `unknown`. The honest fix is a
  `by_task` query, which this slice leaves out to stay in scope. The contract should
  note the coupling so it is not a surprise later.
- **Ask tasks are not reachable by status the same way.** The ask path runs through an
  actor, and its events are stamped by correlation id, not by the task id as a session
  id. The criteria only assert status for a run task, so this slice does not promise
  ask-task status. A client asking status on an ask task id would get `unknown`. This
  is a known limit, not a bug, and belongs in the contract notes.
- **The trace reply's "ending event" depends on timestamp order, not on a terminal
  marker.** `render_lisp/2` sorts by timestamp ascending, so the last sub-form is the
  highest-timestamp event. For a completed run that is `run.completed`. If two events
  share a timestamp the tail order is whatever the sort leaves — unlikely at nanosecond
  resolution, but the test asserts `run.completed` is present and last, not that no
  event could ever tie it.
