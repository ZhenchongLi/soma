# [cc] CLI.1: daemon socket server — Unix-socket listener + JSON protocol + run handler

## Current state

The runtime can drive a supervised run, but nothing outside the BEAM can ask it
to. `soma_agent_session:start_run/2` and the actor both start a `soma_run` under
`soma_run_sup` from inside Erlang. A run reports its terminal state back to its
owner as a `{run_completed | run_failed | run_timeout | run_cancelled, RunId,
...}` message — the actor already drives a run this way, owning it with
`session_pid => self()` (`apps/soma_actor/src/soma_actor.erl`, around line 637).

There is no socket. There is no wire protocol. A caller outside the node — a
shell, Claude Code, Codex — has no way in. `docs/cli.md` is the design draft for
that surface, and this slice builds its server half: a Unix-domain listener, a
length-prefixed JSON frame, and a `run` handler that drives one run and sends the
result back.

OTP 29 ships the `json` module and the codebase already uses it
(`soma_llm_openai.erl`, the LLM call tests). So the wire encoder does not need a
hand-rolled JSON writer or a new dependency. It needs a thin Soma-specific
shaping layer on top of `json`, because two acceptance criteria pin a *specific*
term→JSON shape that `json:encode/1` alone does not produce (atoms and binaries
both become strings; a reason tuple `{Tag, Detail...}` becomes
`{"tag":...,"detail":[...]}`).

## Approach

Add one module, `soma_cli_server`, in `apps/soma_runtime/src/`. It is not wired
under `soma_sup` in this slice — that boot wiring is CLI.1b and out of scope
here. The module is started directly in tests with `start_link(#{socket =>
Path})` against a temp socket path.

Four parts, each separately testable:

**1. Term→JSON shaping.** A pure function turns a Soma result term into the bytes
`json:encode/1` will frame. The shape is fixed by `docs/cli.md` and the first two
criteria:

- atoms → strings, binaries → strings, numbers stay numbers, lists → arrays,
  maps → objects with stringified keys.
- a reason tuple `{Tag, Detail...}` → `{"tag":"<Tag>","detail":[<Detail...>]}`,
  so `{budget_exceeded, max_steps}` → `{"tag":"budget_exceeded","detail":["max_steps"]}`.
  A caller switches on `tag` without parsing a string.

This is a pure term-rewrite into a `json`-encodable form, then `json:encode/1`.
It is tested as a pure function — no socket, no run.

**2. Length-prefix framing.** A frame is a 4-byte big-endian length followed by
the JSON payload. `gen_tcp` with `{packet, 4}` does this framing in the OS/driver
layer, but the round-trip criterion pins the framing as a property the wire
holds, so there is a pure `frame/1` (prepend the 4-byte length) and `unframe/1`
(split length-prefix from payload). Encoding a frame then decoding it yields the
original payload, and decoding a sample frame then re-encoding yields the
original bytes.

**3. The listener.** `start_link(#{socket => Path})` opens an AF_UNIX listener
with `gen_tcp:listen(0, [{ifaddr, {local, Path}}, {packet, 4}, binary, ...])`,
then runs an accept loop. Before bind it unlinks any leftover file at `Path`, so
a restart after a crash that left a stale socket file still binds. Two
single-winner facts the criteria pin: a second `start_link` on a path a live
server already serves fails (the bind cannot take an in-use address) and returns
an error rather than starting a duplicate listener; and the first server keeps
serving after that second attempt fails. The accept loop spawns one handler
process per accepted connection — soma's "one process per unit of work", same
shape as the README's acceptor loop.

The unlink-before-bind needs care: unconditionally unlinking would let a second
`start_link` delete a live server's socket and steal the path, breaking the
single-winner criteria. The design unlinks only a *stale* file — one no live
server answers — so a leftover from a crash is cleared while a live server's path
is left alone. The framing of this in code (probe-then-unlink, or bind-first then
retry once after unlink) is the implementer's, but the two behaviours it must
preserve are both pinned by criteria.

**4. The run handler.** One process per connection. It reads a frame, decodes the
request `{"cmd":"run","workflow":<steps-or-lfe>,"root":?,"timeout_ms":?}`, mints a
`task_id` and a `correlation_id`, and starts a `soma_run` under `soma_run_sup`
that it owns directly — `session_pid => self()`, `correlation_id => CorrId`, the
same direct-ownership pattern the actor uses, no `soma_agent_session` in the
path. The workflow arrives as a JSON step list and is shaped into the step-list
maps `soma_run` accepts. (`docs/cli.md` also allows a `.lfe` workflow compiled
through `soma_lfe:compile/2`; the criteria pin only the JSON step-list path, so
the `.lfe` branch is left for a later cycle per the issue's open question.)

The handler then waits for the run's terminal message. On `run_completed` it
sends a response `{"status":"completed","task_id":...,"correlation_id":...,
"outputs":...}` where `outputs` is the run's recorded step outputs shaped through
the term→JSON layer. On `run_failed` it sends a non-`completed` status and an
`error` field. The handler stays up to answer the next request on a fresh
connection, and a failed run does not stop the server from answering the next
`run`.

**Cancel on disconnect.** The handler links to or monitors its connection. When
the client disconnects mid-run, `gen_tcp` delivers a `{tcp_closed, _}` (or the
monitored socket-owner dies); the handler sends `cancel` to the run pid it owns,
exactly the path `soma_agent_session` uses. The run kills its active tool-call
worker, records `run.cancelled`, and reaches the `cancelled` terminal state — so
the worker is gone afterward. The server keeps serving other connections.

This keeps every non-negotiable constraint: the run is supervised, cancellation
is real (a message to the run that kills the worker, not a flag), the handler
never executes tool logic, and no LLM or external network socket is opened — the
only socket bound is the local Unix test socket.

## Acceptance criteria → tests

### Criterion 1 — term→JSON shapes atoms/binaries/numbers/lists/maps
- Call chain: none (pure function). `soma_cli_server:encode_response/1` (or the
  named term→JSON function) called directly on a sample map.
- Test entry: the term→JSON function. Pure, no socket or run, because the
  criterion is about the encoding shape alone.
- Test: `test_encode_map_atoms_binaries_numbers_lists` in `soma_cli_server_tests`

### Criterion 2 — reason tuple `{budget_exceeded, max_steps}` → tag/detail
- Call chain: none (pure function). The term→JSON function called on the reason
  tuple.
- Test entry: the term→JSON function. Pure, same reason as criterion 1.
- Test: `test_encode_reason_tuple_to_tag_detail` in `soma_cli_server_tests`

### Criterion 3 — length-prefix framing round-trips
- Call chain: none (pure functions). `frame/1` then `unframe/1` on a sample
  request's bytes.
- Test entry: `frame/1` and `unframe/1`. Pure, the criterion is a property of
  the wire bytes (4-byte big-endian length + payload), not of a live socket.
- Test: `test_frame_unframe_round_trips` in `soma_cli_server_tests`

### Criterion 4 — start_link leaves a connectable listening socket
- Call chain: `soma_cli_server:start_link(#{socket => Path})` → accept loop
  listening; a test `gen_tcp:connect({local, Path}, 0, [...])` reaches it.
- Test entry: `start_link/1`, then a real `gen_tcp` client connect. CT, because
  it needs the runtime app up and a live listener.
- Test: `test_start_link_listens_and_accepts_connect` in `soma_cli_server_SUITE`

### Criterion 5 — start_link succeeds over a leftover stale socket file
- Call chain: write a leftover file at `Path` → `start_link(#{socket => Path})`
  → unlink stale file → bind → listening.
- Test entry: `start_link/1` after planting a stale file. CT, real listener.
- Test: `test_start_link_unlinks_stale_socket_file` in `soma_cli_server_SUITE`

### Criterion 6 — second start_link on a live path errors, no duplicate listener
- Call chain: `start_link(#{socket => Path})` (server A live) →
  `start_link(#{socket => Path})` (B) → bind on in-use address fails → `{error,
  _}`.
- Test entry: the second `start_link/1` call, asserting it returns an error and
  no second listener exists. CT, two real bind attempts on one path.
- Test: `test_second_start_link_on_live_path_errors` in `soma_cli_server_SUITE`

### Criterion 7 — first server keeps serving after a second start_link fails
- Call chain: server A live → second `start_link` fails → a `gen_tcp` client
  still connects to A and gets a `run` answer.
- Test entry: a real client connect to A after B's failed bind. CT, proves the
  failed second bind did not disturb A's listener.
- Test: `test_first_server_survives_failed_second_start_link` in `soma_cli_server_SUITE`

### Criterion 8 — run request with one-step echo returns completed + outputs
- Call chain: `gen_tcp` client sends framed `run` request → handler decodes →
  `soma_run_sup:start_run` (owned by handler, `correlation_id` minted) → run
  drives the `echo` step → `run_completed` message to handler → response framed
  back.
- Test entry: a real `gen_tcp` client over the socket (no layer bypassed). CT,
  full server → run → tool-call path.
- Test: `test_run_echo_returns_completed_with_outputs` in `soma_cli_server_SUITE`

### Criterion 9 — a failing step returns non-completed + an error field
- Call chain: client sends `run` whose step fails → handler → run → `run_failed`
  → response with status other than `completed` and an `error` field.
- Test entry: a real `gen_tcp` client over the socket. CT, full failure path.
- Test: `test_run_failed_step_returns_error_status` in `soma_cli_server_SUITE`

### Criterion 10 — server answers a second run after one whose step failed
- Call chain: a failing `run` → response → a second `echo` `run` on a fresh
  connection → `completed` response.
- Test entry: a second real `gen_tcp` client connect after a failed run. CT,
  proves the server survived the failed run.
- Test: `test_server_answers_run_after_failed_run` in `soma_cli_server_SUITE`

### Criterion 11 — client disconnect mid-run cancels the run, worker gone
- Call chain: client sends a `run` with a slow/hanging step → handler owns the
  run → client closes the socket mid-run → handler sends `cancel` to the run →
  run kills its tool-call worker → `cancelled` terminal state.
- Test entry: a real `gen_tcp` client that closes mid-run, then the test asserts
  the run reached `cancelled` and its tool-call worker pid is dead. CT, the
  cancel-on-disconnect path end to end.
- Test: `test_client_disconnect_cancels_run_worker_gone` in `soma_cli_server_SUITE`

### Criterion 12 — server keeps serving after a mid-run disconnect
- Call chain: a mid-run disconnect (criterion 11's setup) → a fresh `gen_tcp`
  client connects and gets an `echo` `run` answered.
- Test entry: a second real client connect after the disconnect. CT, proves the
  server survived the cancelled run.
- Test: `test_server_survives_client_disconnect` in `soma_cli_server_SUITE`

### Criterion 13 — docs/contracts records the CLI.1 proofs
- Call chain: none (direct source-file read). A test reads
  `docs/contracts/v0.7-cli-1-test-contract.md` and asserts it names this slice's
  suite and each case.
- Test entry: a file read, off any call chain, because the criterion is about a
  doc existing and mapping proofs to cases, not about runtime behaviour.
- Test: `test_cli_1_contract_doc_maps_each_proof` in `soma_cli_server_tests`

### Criterion 14 — gate is green, no real LLM or external network socket opened
- Call chain: none (it is the gate itself — `rebar3 eunit && rebar3 ct`).
- Test entry: the full gate run. The CLI.1 suite binds only the local Unix test
  socket; no test in this slice opens a TCP/inet socket or a provider
  connection. Verified by the gate passing with the socket-discipline asserted
  inside `soma_cli_server_SUITE` (the connect uses `{local, Path}`, never an inet
  address).
- Test: the whole `soma_cli_server_SUITE` + `soma_cli_server_tests` under
  `rebar3 eunit && rebar3 ct`

## Risks & trade-offs

- **Unlink-before-bind can race or steal a path.** Unconditional unlink would let
  a second `start_link` delete a live server's socket and break the single-winner
  criteria (6, 7). The design unlinks only a file no live server answers. The
  probe adds a small window: between the probe and the bind another process could
  bind the path. At single-user scale this is acceptable, and criterion 6 pins
  that a concurrent second bind on a live path fails rather than duplicates. The
  honest limit is that the probe-then-bind is not a kernel-atomic single-winner;
  it is single-winner under the single-user assumption `docs/cli.md` states.

- **The handler owns the run directly, no session.** This mirrors the actor and
  keeps the cancel-on-disconnect path short (a `cancel` message to the run). The
  cost is that the CLI run does not appear in any `soma_agent_session`'s run
  view. That is fine for this slice — the session was never in the CLI path by
  design — but it means `soma status` later (CLI.3) reads task state from the run
  or store, not from a session.

- **`{packet, 4}` does the framing in the driver, yet `frame/1`/`unframe/1` also
  exist.** That looks like two framings. The reason is criterion 3 pins the wire
  shape as a property tested in pure Erlang, and a non-Erlang client must
  reproduce it. The pure functions are the documented contract; `{packet, 4}` is
  the runtime convenience that matches it. They must agree on the same 4-byte
  big-endian prefix, and the round-trip test guards that.

- **The `.lfe` workflow path is unbuilt.** `docs/cli.md` allows it and the
  request field accepts it, but no criterion pins it, so the handler decodes only
  the JSON step list in this slice. A `run` carrying `.lfe` source is out of
  scope here and gets its own TDD cycle (the issue's open question). The risk is
  a caller sending `.lfe` and getting a decode error; the response shape for that
  is deferred with the path.
