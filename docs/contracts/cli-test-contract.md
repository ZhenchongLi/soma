# CLI Test Contract — daemon socket server (CLI.1)

This document maps each proof of the CLI.1 daemon-socket-server slice to the
suite and case that proves it. It is the companion to the v0.2–v0.6 contracts and
the design in [../cli.md](../cli.md).

## What this slice builds

The server side of the soma daemon: a Unix-domain (`{local, Path}`) listener with
a length-prefixed JSON wire protocol and a `run` command handler that drives a
supervised `soma_run` the handler owns directly (`session_pid => self()`), then
frames the terminal result back to the client. `soma_cli_server` is in
`apps/soma_runtime/src/`. Single-user / trusted-local — no cross-client auth (see
[../cli.md](../cli.md)). Tested entirely in-BEAM: pure encode/frame as EUnit, the
socket + run paths as Common Test with a real `gen_tcp` client over a temp socket.

**Deferred to CLI.1.5:** cancel-on-disconnect (a handler that cancels its
in-flight run when the client disconnects). Under the single-user scope an
orphaned run is a small waste, not a fault; it is its own slice because it adds
handler concurrency (watching the socket while awaiting the run) that deserves its
own TDD cycle rather than a hand-rolled addition here. The thin `soma run` client
binary and `soma daemon` boot command are CLI.1b.

## Locked design decisions the proofs lean on

1. **One process per connection.** The accept loop spawns a handler per accepted
   socket; a handler reads one framed request, runs it, frames the reply, closes.
   A failing run is data in the reply, never a handler or listener crash.
2. **`{packet, 4}` framing.** The listener and clients use a 4-byte big-endian
   length prefix; `frame/1` + `unframe/1` are the pure contract a non-Erlang
   client reproduces.
3. **JSON → step shaping.** A request's JSON step list becomes the atom-keyed step
   maps `soma_run` accepts; the tool name is resolved with
   `binary_to_existing_atom/2` so an unknown tool cannot grow the atom table.
4. **`jsonable/1` is total.** Every response term is made JSON-encodable before
   `json:encode/1`: tuples (which the encoder rejects) — including a failure
   `reason` nested under `error` — become `{"tag": First, "detail": [Rest...]}`,
   maps and lists recurse, and pids/refs/funs are rendered to a string rather than
   crashing the encoder.
5. **Stale-socket cleanup + single-winner bind.** A leftover socket file is
   unlinked before bind only when no live server answers a probe connect, so a
   restart after a crash binds while a second `start_link` on a live path fails
   rather than stealing it.

## Proving suite

Pure protocol shaping — `apps/soma_runtime/test/soma_cli_server_tests.erl` (EUnit):

| # | Proof | Case |
|---|---|---|
| 1 | a map of atom/binary/number/list values encodes to the matching JSON object | `encode_map_atoms_binaries_numbers_lists_test` |
| 2 | the reason tuple `{budget_exceeded, max_steps}` encodes to `{"tag":"budget_exceeded","detail":["max_steps"]}` | `encode_reason_tuple_to_tag_detail_test` |
| 3 | the 4-byte length prefix round-trips (`frame`/`unframe`) | `frame_unframe_round_trips_test` |

Listener, lifecycle, and run paths — `apps/soma_runtime/test/soma_cli_server_SUITE.erl` (CT, real `gen_tcp` client over a temp Unix socket):

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
