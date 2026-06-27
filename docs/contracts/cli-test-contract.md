# CLI Test Contract — daemon socket server (CLI.1)

This document maps each proof of the CLI.1 daemon-socket-server slice to the
suite and case that proves it. It is the companion to the v0.2–v0.6 contracts and
the design in [../cli.md](../cli.md).

> **Superseded by the Lisp wire (CLI.1b + CLI.1c).** This slice's original wire was
> JSON; CLI.1b added the Lisp `(run …)` / `(result …)` wire and CLI.1c removed JSON
> entirely. The JSON-specific proofs below — the `encode_*` term→JSON tests
> (criteria 1–2) and the JSON `test_run_*` run tests (criteria 8–10), now removed —
> are superseded; the surviving CLI.1 proofs are the framing round-trip (3) and the
> listener/lifecycle (4–7). The live run-path proofs are in
> [cli-1b-test-contract.md](cli-1b-test-contract.md).

## What this slice builds

The server side of the soma daemon: a Unix-domain (`{local, Path}`) listener with
a length-prefixed s-expr wire protocol and a handler that reads a `(run …)`
request s-expr, parses it with `soma_lfe`, drives a supervised `soma_run` the
handler owns directly (`session_pid => self()`), and frames a rendered
`(result …)` reply s-expr (`soma_lisp:render/1`) back to the client. There is no
JSON on the wire — the same Lisp the workflows are written in is the wire format.
`soma_cli_server` is in `apps/soma_runtime/src/`. Single-user / trusted-local — no
cross-client auth (see [../cli.md](../cli.md)). Tested entirely in-BEAM: pure
encode/frame as EUnit, the socket + run paths as Common Test with a real
`gen_tcp` client over a temp socket.

**Cancel-on-disconnect is CLI.1.5** (delivered — see the proof section below): a
handler that cancels its in-flight run when the client disconnects. Under the
single-user scope an orphaned run is a small waste, not a fault; it is its own
slice because it adds handler concurrency (watching the socket while awaiting the
run) that deserves its own TDD cycle rather than a hand-rolled addition here. The
thin `soma run` client binary and `soma daemon` boot command are CLI.1b.

## Locked design decisions the proofs lean on

1. **One process per connection.** The accept loop spawns a handler per accepted
   socket; a handler reads one framed request, runs it, frames the reply, closes.
   A failing run is data in the reply, never a handler or listener crash.
2. **`{packet, 4}` framing.** The listener and clients use a 4-byte big-endian
   length prefix; `frame/1` + `unframe/1` are the pure contract a non-Erlang
   client reproduces.
3. **Lisp `(run …)` → step shaping.** A request's `(run …)` s-expr is parsed by
   `soma_lfe:compile/2` into the step-list maps `soma_run` accepts; the tool name
   is resolved with `binary_to_existing_atom/2` so an unknown tool cannot grow the
   atom table.
4. **`(result …)` rendering is total.** Every terminal outcome is rendered to a
   `(result …)` s-expr by `soma_lisp:render/1`: the terminal `status`, the
   `outputs`, the `task_id` / `correlation_id`, and — on failure — the `reason`,
   all as Lisp forms the client prints verbatim.
5. **Stale-socket cleanup + single-winner bind.** A leftover socket file is
   unlinked before bind only when no live server answers a probe connect, so a
   restart after a crash binds while a second `start_link` on a live path fails
   rather than stealing it.

## Proving suite

Pure protocol shaping — `apps/soma_actor/test/soma_cli_server_tests.erl` (EUnit):

| # | Proof | Case |
|---|---|---|
| 1 | a map of atom/binary/number/list values encodes to the matching JSON object | `encode_map_atoms_binaries_numbers_lists_test` |
| 2 | the reason tuple `{budget_exceeded, max_steps}` encodes to `{"tag":"budget_exceeded","detail":["max_steps"]}` | `encode_reason_tuple_to_tag_detail_test` |
| 3 | the 4-byte length prefix round-trips (`frame`/`unframe`) | `frame_unframe_round_trips_test` |

Listener, lifecycle, and run paths — `apps/soma_actor/test/soma_cli_server_SUITE.erl` (CT, real `gen_tcp` client over a temp Unix socket):

| # | Proof | Case |
|---|---|---|
| 4 | `start_link` leaves a listening socket a client connects to | `test_start_link_listens_and_accepts_connect` |
| 5 | a leftover file at the path is unlinked before bind | `test_start_link_unlinks_stale_socket_file` |
| 6 | a second `start_link` on a live path errors (no duplicate listener) | `test_second_start_link_on_live_path_errors` |
| 7 | the first server keeps serving after the failed second `start_link` | `test_first_server_survives_failed_second_start_link` |
| 8 | a one-step `echo` run returns `completed` + `task_id` + `correlation_id` + `outputs` | `test_run_echo_returns_completed_with_outputs` |
| 9 | a run whose step fails returns a non-`completed` status with an `error` | `test_run_failed_returns_failed_with_error` |
| 10 | the server serves a later request after a failed run | `test_server_serves_after_failed_run` |

> Environment note: AF_UNIX socket operations on macOS can intermittently return
> `eopnotsupp`/timeouts under heavy concurrent load; the CT cases above are
> deterministic in isolation. This is the same load-sensitivity tracked for
> `soma_cli_lifecycle_SUITE`.

## Cancel-on-disconnect (CLI.1.5)

This slice gives the connection handler one new behavior: while it awaits its
in-flight `soma_run`, it also watches the client socket (`{active, once}`), and a
mid-run `{tcp_closed, _}` cancels the live run rather than orphaning it. Under the
single-user scope an orphaned run is a small waste, not a fault — but the cancel is
real (cancel → message to `soma_run` → it stops the active tool-call worker →
`run.cancelled`), the same cancellation contract the v0.1 core proves. Each
connection handler is independent, so cancelling one run does not disturb the
listener or other connections.

The three proofs live in
`apps/soma_actor/test/soma_cli_server_SUITE.erl` (CT, real `gen_tcp` client over
a temp Unix socket). Each drives a slow `sleep` step, waits for the run's
`tool.started` event in the store so the disconnect lands while a worker is live,
then closes the socket:

| # | Proof | Case |
|---|---|---|
| 1 | a client that closes the socket mid-run drives that run to `cancelled` — a `run.cancelled` event for the run appears in the store | `test_run_cancelled_on_client_disconnect` |
| 2 | after the mid-run disconnect, the cancelled run's active tool-call worker (its pid read off `tool.started`) is no longer alive — the cancel stopped the live worker, it was not a flag checked later | `test_worker_dead_after_client_disconnect` |
| 3 | the same server still serves a fresh connection after a mid-run disconnect — a second connection's echo run returns a `completed` `(result …)` with s1's value | `test_server_serves_after_client_disconnect` |
