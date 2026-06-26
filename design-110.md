# [cc] CLI.1b: full Lisp wire — soma run flow.lfe + soma daemon

## Current state

`soma_cli_server` speaks JSON on the wire. The handler reads one framed request,
calls `json:decode/1`, expects a `#{<<"cmd">> := <<"run">>, <<"workflow">> := [...]}`
map, shapes each JSON step with `shape_step/1` (binary keys → atom-keyed step map,
tool name through `binary_to_existing_atom/2`), starts a `soma_run` it owns
(`session_pid => self()`), waits for the terminal message, builds a result map,
and sends it back through `encode_response/1` + `jsonable/1` (term → JSON).

The building blocks for the Lisp wire are already on `main`:

- `soma_lfe:compile/2` parses a constrained Lisp grammar. Its `dispatch/1` routes
  a single `(msg ...)` to `parse_msg`, a `(reply ...)` / `(run-steps ...)` to
  `parse_proposal`, and everything else to `parse_run`. `parse_run/1` requires
  exactly one top-level form headed by `run`: `(run (step ...) (step ...))`. It
  returns `{ok, #{run => #{steps => [StepMap]}}}` or `{error, [Diagnostic]}`.
  Step ids and tool names parse as atoms; string args parse as binaries.
- `soma_lisp:render/1` (L.4) renders a term as a Lisp s-expr. A map that carries
  `status` + `outputs` + `correlation_id` renders as `(result (status ...)
  (outputs ...) (correlation-id ...))`. Other maps render as event / envelope /
  generic forms. Atoms render as symbols with `_` → `-`, binaries as quoted
  strings.
- `soma_run` reports `{run_completed, RunId, Outputs}` to its `session_pid`,
  where `Outputs` is keyed by the step's atom id and an echo step's value is
  `#{value => <<"hi">>}`. Failures report `{run_failed, RunId, Reason}`,
  `{run_timeout, RunId}`, `{run_cancelled, RunId}`.

Two gaps stop the Lisp wire from closing:

1. `soma_lisp:render/1` only emits `(result ...)` when the map has all three of
   `status` / `outputs` / `correlation_id`. A failed run carries `error` and no
   `outputs`, so its result map falls through to the generic map clause and does
   not render as a `(result ...)`.
2. There is no `soma_cli` client module, and no `soma daemon` boot path beyond
   `soma_cli_server:start_link/1`.

## Approach

Target state: `soma run flow.lfe` sends the file's s-expr to the daemon; the
daemon parses it with `soma_lfe`, runs it supervised, renders the result with
`soma_lisp`, and the client prints that s-expr. No JSON on the wire.

### Open question 1 — request shape

The request is `(run (step ...) ...)`. `soma_lfe:compile/2` already has a
`parse_run` path that accepts exactly that: a single top-level form headed by
`run` whose children are `(step ...)` forms. So no new dispatch clause is needed.
The handler hands the raw request bytes to `soma_lfe:compile/2` and gets back
`{ok, #{run => #{steps => Steps}}}`. The `Steps` are the atom-keyed step maps
`soma_run` already accepts. `shape_step/1` and `binary_to_existing_atom/2` go
away; `soma_lfe` does that shaping now.

Decision: keep the request as `(run (step ...) ...)`, parse it through the
existing `parse_run` path, add no `run` head clause to `soma_lfe`.

The `docs/lisp-messages.md` sketch shows a richer `(run (msg (type chat) (steps
...)))` form. That nested form is not what `parse_run` accepts today, and wiring
it would pull in `parse_msg`'s envelope handling, which is out of scope here. The
criteria only require the request to parse through `soma_lfe` and carry one
`(step ...)`; the flat `(run (step ...) ...)` form meets that and is what the
parser already supports. The doc update below records the flat form as the wire
request.

### Open question 2 — malformed-request reply

A malformed Lisp request is one where `soma_lfe:compile/2` returns
`{error, Diagnostics}` (a parse / grammar failure), or where the reader itself
fails. The handler catches that branch and replies with a defined error s-expr
rather than crashing.

Decision: render the malformed-request reply as a `(result ...)` with
`status => error` and an `error` sub-form carrying the diagnostics. This reuses
the same `(result ...)` head as every other reply, so the client has one shape to
read. It depends on the failed-result rendering from open question 3 (a result
map that carries `error` and no `outputs`).

### Open question 3 — failed-run and error result rendering

`soma_lisp:render/1` must render a result map that carries `error` and may lack
`outputs`. The chosen marker for "this is a result form" is the presence of
`status` plus either `outputs` or `error`. When `outputs` is absent, the
`(outputs ...)` sub-form is omitted and an `(error ...)` sub-form is emitted in
its place; `correlation_id` stays optional in the malformed case (a parse failure
happens before a run, so there is no correlation id to carry).

Concretely the renderer's result clause emits, in order: `(status <S>)`, then
`(outputs ...)` if the map has `outputs`, then `(error ...)` if the map has
`error`, then `(correlation-id ...)` if the map has `correlation_id`. The existing
fixed-order completed-result rendering (`status outputs correlation-id`) is
preserved so `soma_lisp_tests` stays green.

### Handler flow

```
handle(Socket)
  → recv framed bytes
  → soma_lfe:compile(Bytes, #{})
      ├─ {ok, #{run := #{steps := Steps}}}
      │     → mint task/corr/run ids
      │     → soma_run_sup:start_run(#{... session_pid => self(), steps => Steps})
      │     → await_run → result map (#{status, outputs|error, correlation_id})
      │     → soma_lisp:render → frame → send
      └─ {error, Diagnostics}
            → #{status => error, error => Diagnostics}
            → soma_lisp:render → frame → send
```

The compile call is wrapped so a reader crash on garbage bytes becomes the same
`{error, _}` reply path, not a handler crash. The handler still closes the socket
after one reply, one process per connection, exactly as CLI.1.

### `soma_cli` client

A new `soma_cli` module in `apps/soma_runtime/src/` with `run/1` and `daemon/1`.

- `run(Args)`: resolves the workflow source (a file path, or stdin when the path
  arg is `-`), connects to the resolved socket path with `{packet, 4}`, frames
  and sends the source bytes, reads the framed `(result ...)` reply, prints it to
  stdout, and returns an exit code. Exit `0` when the reply's status sub-form is
  `completed`, non-zero otherwise. The client sends the workflow source through
  unchanged — it does not parse Lisp; the daemon is the parser.
- `daemon(Args)`: boots the runtime (`application:ensure_all_started(soma_runtime)`)
  and starts a listener on a resolved socket path
  (`soma_cli_server:start_link(#{socket => Path})`), then stays up. Socket path
  resolution mirrors `docs/cli.md`: `$XDG_RUNTIME_DIR/soma.sock`, else
  `/tmp/soma-$UID.sock`, with a test-supplied override so a suite can point both
  ends at a temp path.

The `soma` escript/release entry is thin glue over `soma_cli` and is exercised by
the end-to-end path, not unit-tested (per the issue's out-of-scope note).

### Reading the completed-reply status in the client and tests

The reply is an s-expr, not a map. To check "status is completed" the client and
the CT cases parse the reply back with `soma_lfe` or match on the rendered bytes.
The simplest robust check is a substring match for `(status completed)` in the
framed payload, which the tests already do for event fields in `soma_lisp_tests`.
The client uses the same check to pick its exit code.

## Acceptance criteria → tests

### Criterion 1 — completed run replies a `(result ...)` with `completed` status and the echo output
- Call chain: gen_tcp client → `soma_cli_server` accept loop → `handle/1` →
  `soma_lfe:compile/2` → `soma_run_sup:start_run` → `soma_run` →
  `soma_tool_call` (echo) → `await_run` → `soma_lisp:render/1` → framed reply
- Test entry: a real `gen_tcp` client over a temp Unix socket (no layer bypassed)
- Test: `test_run_lisp_echo_returns_completed_result` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 2 — the completed `(result ...)` carries a non-empty `correlation-id`
- Call chain: same as Criterion 1
- Test entry: same `gen_tcp` client; asserts the reply contains a non-empty
  `(correlation-id "...")` sub-form
- Test: `test_run_lisp_result_carries_correlation_id` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 3 — the `run` path uses `soma_lfe` + `soma_lisp`, never `json:decode` / `json:encode`
- Call chain: none (direct source-file read)
- Test entry: a source-text assertion that `soma_cli_server.erl`'s handler /
  run path contains no `json:decode` or `json:encode` call and references
  `soma_lfe` and `soma_lisp`
- Test: `test_run_path_uses_lisp_not_json` in
  `apps/soma_runtime/test/soma_cli_server_tests.erl`

### Criterion 4 — a failed run replies a `(result ...)` with non-`completed` status and an error sub-form
- Call chain: gen_tcp client → accept loop → `handle/1` → `soma_lfe:compile/2`
  → `soma_run_sup:start_run` → `soma_run` → `soma_tool_call` (`fail`) →
  `await_run` (`run_failed`) → `soma_lisp:render/1` → framed reply
- Test entry: a real `gen_tcp` client; the request's only step uses the `fail`
  tool
- Test: `test_run_lisp_failed_returns_error_result` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 5 — the server stays up after a failed run and answers the next request on a new connection
- Call chain: two sequential gen_tcp connections through the chain of Criterion 4
  then Criterion 1
- Test entry: a real `gen_tcp` client; first connection fails a run, second
  connection runs an echo and gets `completed`
- Test: `test_server_serves_after_failed_lisp_run` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 6 — a malformed Lisp request replies a defined error s-expr, no handler crash
- Call chain: gen_tcp client → accept loop → `handle/1` → `soma_lfe:compile/2`
  (returns `{error, _}`) → `soma_lisp:render/1` of an error result map → framed
  reply
- Test entry: a real `gen_tcp` client sends bytes that do not parse; asserts the
  reply is a parseable s-expr with `(status error)` and an `(error ...)` sub-form
- Test: `test_malformed_request_returns_error_sexpr` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 7 — the server stays up after a malformed request and answers the next well-formed request
- Call chain: two sequential gen_tcp connections — Criterion 6 then Criterion 1
- Test entry: a real `gen_tcp` client; first connection sends garbage, second
  connection runs an echo and gets `completed`
- Test: `test_server_serves_after_malformed_request` in
  `apps/soma_runtime/test/soma_cli_server_SUITE.erl`

### Criterion 8 — `soma_cli:run/1` reads a `.lfe` file, prints the `(result ...)`, returns exit 0
- Call chain: `soma_cli:run/1` → read file → connect temp socket → frame+send →
  `soma_cli_server` chain (Criterion 1) → read reply → print → exit code
- Test entry: `soma_cli:run/1` with a temp `.lfe` file and a temp socket served
  by a real `soma_cli_server`
- Test: `test_run_echo_file_prints_result_exit_zero` in
  `apps/soma_runtime/test/soma_cli_SUITE.erl`

### Criterion 9 — `soma_cli:run/1` returns non-zero when the run does not reach `completed`
- Call chain: `soma_cli:run/1` → read file (a `fail` step) → connect → server
  chain (Criterion 4) → read reply → exit code
- Test entry: `soma_cli:run/1` with a `.lfe` file whose only step fails
- Test: `test_run_failed_workflow_exit_nonzero` in
  `apps/soma_runtime/test/soma_cli_SUITE.erl`

### Criterion 10 — `soma_cli:run/1` reads the workflow from stdin when the path arg is `-`
- Call chain: `soma_cli:run/1` (path arg `-`) → read stdin → connect → server
  chain → read reply → print → exit code
- Test entry: `soma_cli:run/1` with `-`; the test feeds the workflow on a
  redirected stdin (a captured / piped group leader)
- Test: `test_run_reads_workflow_from_stdin_dash` in
  `apps/soma_runtime/test/soma_cli_SUITE.erl`

### Criterion 11 — `soma_cli:daemon/1` boots the runtime + listener on a resolved path, a client connects
- Call chain: `soma_cli:daemon/1` → `application:ensure_all_started(soma_runtime)`
  → `soma_cli_server:start_link(#{socket => Path})`; then a real gen_tcp client
  connects to that path
- Test entry: `soma_cli:daemon/1` with a temp socket override, then a `gen_tcp`
  connect to the resolved path
- Test: `test_daemon_boots_listener_client_connects` in
  `apps/soma_runtime/test/soma_cli_SUITE.erl`

### Criterion 12 — the CLI.1b test contract names a suite + case for each proof
- Call chain: none (direct source-file read)
- Test entry: off the call chain — this is a docs deliverable, verified by the
  contract file existing and mapping each CLI.1b proof to its suite + case
- Test: `docs/contracts/cli-1b-test-contract.md` (the mapping table itself; no
  test function)

### Criterion 13 — neither `docs/cli.md` nor `docs/contracts/cli-test-contract.md` describes a JSON wire for `soma run`
- Call chain: none (direct source-file read)
- Test entry: off the call chain — a docs edit; the two files describe the Lisp
  `(run ...)` request and `(result ...)` reply and drop the JSON-wire wording
- Test: prose in `docs/cli.md` and `docs/contracts/cli-test-contract.md` (no test
  function)

### Criterion 14 — CLI.1b test sources carry no real-provider marker and open no non-local socket
- Call chain: none (compile-time / source assertion)
- Test entry: off the call chain — a source scan of the CLI.1b test files for the
  markers `soma_llm_openai` / `api_key` / `base_url` / `http` / `https` and for
  any non-`{local, _}` socket open
- Test: `test_cli_1b_sources_have_no_real_provider_or_socket_marker` in
  `apps/soma_runtime/test/soma_cli_1b_marker_tests.erl`

## Risks & trade-offs

- The wire request is the flat `(run (step ...) ...)` form, not the nested
  `(run (msg (steps ...)))` shown in `docs/lisp-messages.md`. The flat form is
  what `soma_lfe:parse_run` accepts today, and the criteria only require parsing
  through `soma_lfe`. The cost: `docs/lisp-messages.md`'s sketch and the actual
  wire diverge until the envelope form is wired (a later slice). The doc updates
  here record the flat form so a reader is not misled.

- Checking "status is completed" by substring-matching `(status completed)` in
  the rendered reply is looser than re-parsing the reply into a term. It is the
  same technique `soma_lisp_tests` already uses for event fields, and the reply
  shape is fixed by the renderer, so a false match is unlikely. If the reply
  grammar grows, the client should re-parse instead.

- Reading stdin for the `-` path in a test means redirecting the group leader,
  which is fiddlier than a file read and can be brittle across OTP versions. If
  the group-leader approach proves flaky, the test can drive a small internal
  read helper directly and prove the `-` dispatch separately from the byte source.

- The malformed-request reply has no correlation id (the failure precedes a run).
  A client that keys on correlation id for every reply must tolerate its absence
  on the error path. The reply still parses as a `(result ...)`, so the shape
  contract holds.
