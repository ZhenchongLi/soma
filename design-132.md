# [cc] CLI.5: soma command argv dispatch + shared socket-path resolution

## Current state

The daemon clients exist only as Erlang functions in `apps/soma_actor/src/soma_cli.erl`:
`run/1`, `ask/1`, `status/1`, `cancel/1`, `trace/1`, `daemon/1`. Every one of them
takes a pre-built map that already has `socket := Path` and the command-specific key
(`file`, `intent`, `task_id`, `correlation_id`). Nobody fills that map from a real
command line. There is no argv entrypoint, so a human or an agent cannot type
`soma run flow.lfe` — they would have to open an Erlang shell and hand-build the map.

Two more gaps make the daemon and a client fail to meet on the same socket.

The fallback socket path is computed in two unrelated places. `daemon/1` calls a
private `socket_path/1` (line 127). A client has no resolver at all — the caller
hard-codes `socket` into the map. So a separately-launched daemon and a separately-
launched client only land on the same path when `XDG_RUNTIME_DIR` is set and both
read it. When it is unset, `socket_path/1` at line 132 falls back to
`/tmp/soma-<os:getpid()>.sock`. That uses the daemon BEAM's OS pid, a value a client
process can never reproduce. The two never rendezvous. The doc comment even claims
`/tmp/soma-$UID.sock`, but the code does not do that.

The intent string is interpolated into the wire s-expr raw. `ask_source/1` builds
`(ask (intent "..." ))` by sticking the intent bytes straight between the quotes.
An intent like `say "hi"` produces `(ask (intent "say "hi""))`, which the daemon's
reader does not parse as one string. The same hole exists for any user string that
contains `"` or `\`.

## Approach

Add one new module, `soma_cli_main`, in `apps/soma_actor/src/`. It is the command
brain: argv in, an OS exit code out. It does not open sockets or render Lisp itself —
it parses argv into the same map shape the existing `soma_cli:*` functions already
take, fills in the socket path, and calls them. This keeps the wire and rendering
logic where it already lives and tested.

`dispatch/1` is the testable core. It takes an argv list and returns an integer. It
never halts the OS process and never crashes on bad input — a malformed command is a
usage message on stderr plus a non-zero return, not an exception. `main/1` is the
thin OS shell on top: it calls `dispatch/1` and `halt/1`s with the returned integer.
Splitting them this way means every behavior is provable by calling `dispatch/1` and
reading the integer, with no subprocess and no captured `halt`.

Argv parsing is small and hand-written. The first token is the subcommand. The
remaining tokens are the positional argument plus the flags `--detach`, `--socket
<path>`. `--detach` only applies to `run` and `ask`; it sets `detach => true` in the
map, which the existing `run_source` / `ask_source` already turn into the `(detach)`
marker. `--socket <path>` overrides the resolved path for any subcommand. Anything
the parser does not recognize — unknown subcommand, missing positional, no subcommand
at all — returns the usage path: print usage to stderr, return non-zero, leave stdout
clean.

The socket resolver moves into one shared function and both sides call it.
`soma_cli:daemon/1`'s private `socket_path/1` is replaced by a call to the shared
resolver, and `soma_cli_main` calls the same resolver when no `--socket` override is
given. The resolver's rule: `--socket`/`socket` override wins; else
`$XDG_RUNTIME_DIR/soma.sock`; else a stable per-user `/tmp/soma-<user>.sock`. The
per-user fallback derives the `<user>` segment from the real user identity, not
`os:getpid()`. I will use the numeric uid from `os:cmd("id -u")` trimmed, or the
`$USER`/`$LOGNAME` env value — whichever the implementer picks, the criterion only
fixes the path *shape* and that it is identical across two separate OS processes for
the same user. The point is that it is reproducible from the user's identity, which
a pid is not.

Where the shared resolver lives: it is exported from `soma_cli` (the module both the
daemon path and the new dispatch already depend on), so `soma_cli_main` reaches it
without a new dependency edge and `daemon/1` calls it in-module. New code stays in
`apps/soma_actor/src/`; the one-way dependency on `soma_runtime` is unchanged.

Intent escaping: add a small escaper that backslash-escapes `"` and `\` in any user
string before it goes between s-expr quotes, and route `ask`'s intent (and any other
user-supplied string the client quotes) through it. The round-trip test proves the
escaped bytes parse back to the original string at the daemon.

The wire is untouched — still all-Lisp, `{packet, 4}`-framed, bare s-exprs, no JSON.
This slice adds no new request or reply form; it only constructs the same requests
the existing clients already send.

## Acceptance criteria → tests

All dispatch tests live in a new CT suite `soma_cli_dispatch_SUITE` under
`apps/soma_actor/test/`. The suite prefix is `soma_cli_dispatch_` — not `soma_cli_`
or `soma_cli_c_` — to keep it off the known cross-BEAM socket-path-collision flake.
It boots a real `soma_cli_server` on a unique per-run socket
(`$TMPDIR` + `os:getpid()` + `erlang:unique_integer` + pre-delete) and asserts the
server still serves the next request, not just the return value.

The resolver criteria and the malformed-input criteria do not need a live socket;
they are pure unit checks in a new EUnit module `soma_cli_main_tests` and the shared
resolver checks in `soma_cli_resolver_tests`. The argv `main/1` halt behavior is a
source/structure assertion (a real `halt/1` can't run inside the gate), noted per
criterion.

### Criterion 1 — `run File` runs the file through the daemon and mirrors `run/1`'s exit code
- Call chain: `soma_cli_main:dispatch(["run", File])` → resolve socket → `soma_cli:run/1` → connect/frame/send → server runs the workflow → `(result …)` reply → `exit_code/1`
- Test entry: `soma_cli_main:dispatch/1` (full chain, real server on a temp socket)
- Test: `test_dispatch_run_file_completed_exit_zero` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 2 — `run -` reads the workflow from stdin
- Call chain: `soma_cli_main:dispatch(["run", "-"])` → `soma_cli:run/1` → `read_source("-")` → stdin to EOF → server → `(result …)`
- Test entry: `soma_cli_main:dispatch/1`, run in a child process with a fake IO server as group leader (the stdin pattern `soma_cli_SUITE` already uses)
- Test: `test_dispatch_run_dash_reads_stdin` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 3 — `ask Intent` drives `ask/1` and returns its exit code
- Call chain: `soma_cli_main:dispatch(["ask", Intent])` → resolve socket → `soma_cli:ask/1` → server's mock `model_config` yields a reply → `(result …)` → `exit_code/1`
- Test entry: `soma_cli_main:dispatch/1` (server started with a mock proposal directive)
- Test: `test_dispatch_ask_completed_exit_zero` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 4 — `status TaskId` drives `status/1`, exit 0 on a successful read
- Call chain: seed a task via a real run, then `soma_cli_main:dispatch(["status", TaskId])` → `soma_cli:status/1` → `(status (state …))` reply → return 0
- Test entry: `soma_cli_main:dispatch/1`
- Test: `test_dispatch_status_read_exit_zero` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 5 — `trace CorrId` drives `trace/1`, exit 0 on a successful read
- Call chain: seed a correlation chain via a real run, then `soma_cli_main:dispatch(["trace", CorrId])` → `soma_cli:trace/1` → `(trace …)` reply → return 0
- Test entry: `soma_cli_main:dispatch/1`
- Test: `test_dispatch_trace_read_exit_zero` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 6 — `cancel TaskId` drives `cancel/1`, exit 0 on a successful cancel
- Call chain: seed a running detached task, then `soma_cli_main:dispatch(["cancel", TaskId])` → `soma_cli:cancel/1` → `(result (status cancelled) …)` → return 0
- Test entry: `soma_cli_main:dispatch/1`
- Test: `test_dispatch_cancel_running_task_exit_zero` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 7 — `--detach` after `run`/`ask` sets `detach => true`, request carries `(detach)`
- Call chain: `soma_cli_main:dispatch(["run", File, "--detach"])` → map has `detach => true` → `soma_cli:run/1` → `run_source` adds the marker → request bytes carry `(detach)`
- Test entry: `soma_cli_main:dispatch/1`, with `soma_cli_request_capture` standing in for the server so the test reads the actual wire bytes (the capture pattern `soma_cli_SUITE` already uses)
- Test: `test_dispatch_run_detach_marks_request` and `test_dispatch_ask_detach_marks_request` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 8 — `--socket <path>` overrides the resolved path for any subcommand
- Call chain: `soma_cli_main:dispatch(["status", TaskId, "--socket", Path])` → the map's `socket` is `Path`, not the resolver's value → `soma_cli:status/1` connects to `Path`
- Test entry: `soma_cli_main:dispatch/1`; the server is on `Path` while `XDG_RUNTIME_DIR` is set to a different directory, so a successful read proves the override won
- Test: `test_dispatch_socket_override_wins` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 9 — resolver returns `$XDG_RUNTIME_DIR/soma.sock` when set
- Call chain: none (direct function call on the shared resolver)
- Test entry: the shared resolver, with `XDG_RUNTIME_DIR` set in the test
- Test: `test_resolver_uses_xdg_runtime_dir` in `apps/soma_actor/test/soma_cli_resolver_tests.erl`

### Criterion 10 — resolver returns a stable per-user `/tmp/soma-<user>.sock` when XDG is unset, identical across two processes
- Call chain: none (direct function call on the shared resolver)
- Test entry: the shared resolver with `XDG_RUNTIME_DIR` unset; call it twice — once in this process, once in a spawned process — and assert both return the same path matching `/tmp/soma-<user>.sock`
- Test: `test_resolver_per_user_path_stable_across_processes` in `apps/soma_actor/test/soma_cli_resolver_tests.erl`

### Criterion 11 — the per-user path is not derived from `os:getpid()`
- Call chain: none (compile-time / source-scan assertion plus a runtime check)
- Test entry: the shared resolver — assert the resolved per-user path does not contain this process's `os:getpid()`, and a source scan of `soma_cli.erl` confirms the per-user branch no longer calls `os:getpid()`
- Test: `test_resolver_per_user_path_not_from_getpid` in `apps/soma_actor/test/soma_cli_resolver_tests.erl`

### Criterion 12 — `daemon/1` and dispatch resolve the same path for the same user
- Call chain: `soma_cli:daemon/1`'s path resolution and `soma_cli_main`'s no-override path both call the shared resolver
- Test entry: the shared resolver — drive `daemon/1`'s resolution and the dispatch resolution with `XDG_RUNTIME_DIR` unset and assert the two paths are equal
- Test: `test_daemon_and_dispatch_resolve_same_path` in `apps/soma_actor/test/soma_cli_resolver_tests.erl`

### Criterion 13 — a user string with `"` or `\` is escaped and round-trips intact
- Call chain: `soma_cli_main:dispatch(["ask", "say \"hi\""])` → escaper → `(ask (intent "say \"hi\""))` request bytes → server's reader parses it → the intent the actor sees is the original `say "hi"`
- Test entry: `soma_cli_main:dispatch/1`, with the server's mock echoing the parsed intent back so the reply proves the string reached the daemon intact
- Test: `test_dispatch_ask_intent_with_quotes_round_trips` in `apps/soma_actor/test/soma_cli_dispatch_SUITE.erl`

### Criterion 14 — unknown subcommand / missing arg / no subcommand prints usage to stderr, non-zero exit, stdout clean
- Call chain: `soma_cli_main:dispatch(BadArgv)` → usage path → stderr write → non-zero return
- Test entry: `soma_cli_main:dispatch/1` with `[]`, `["bogus"]`, and `["run"]` (missing file); capture stdout and stderr and assert stdout is empty, stderr carries usage, return is non-zero
- Test: `test_dispatch_malformed_prints_usage_nonzero` in `apps/soma_actor/test/soma_cli_main_tests.erl`

### Criterion 15 — `dispatch/1` returns an integer, never crashes or badmatches on malformed input
- Call chain: `soma_cli_main:dispatch(BadArgv)` → usage path → integer return
- Test entry: `soma_cli_main:dispatch/1` over a table of malformed inputs (the criterion-14 set plus an unknown flag and a `--socket` with no value); assert each return is an integer
- Test: `test_dispatch_malformed_returns_integer` in `apps/soma_actor/test/soma_cli_main_tests.erl`

### Criterion 16 — `main/1` halts with the `dispatch/1` integer and routes diagnostics to stderr
- Call chain: `soma_cli_main:main(Argv)` → `dispatch/1` → `halt(Integer)`
- Test entry: off the call chain — `halt/1` ends the BEAM, so the gate cannot run `main/1` directly. The proof is a source-structure assertion that `main/1` calls `dispatch/1` and passes its result to `halt/1`, and that its only diagnostic output goes to `standard_error`. Reason for the off-chain entry: a real `halt/1` would kill the test runner.
- Test: `test_main_halts_with_dispatch_code` in `apps/soma_actor/test/soma_cli_main_tests.erl`

### Contract + marker deliverables (carried conventions)
- A contract doc `docs/contracts/cli-5-test-contract.md` names every suite/module above and each case, mirroring `cli-3-test-contract.md`. Checked by `soma_cli_5_contract_tests` in `apps/soma_actor/test/`.
- A no-network marker scan over the new test sources, mirroring `soma_cli_3_marker_tests`. Checked by `soma_cli_5_marker_tests` in `apps/soma_actor/test/`.

## Risks & trade-offs

The per-user identity source is left open by the issue. Reading the uid via
`os:cmd("id -u")` spawns a shell-free external program and adds a tiny startup cost
on every client invocation. Reading `$USER`/`$LOGNAME` is cheaper but can be unset or
spoofed in a stripped environment, and then the resolver has no user to key on. The
fallback if neither is available has to be decided by the implementer; whatever it
is, it must stay stable across two processes for the same user, so it cannot quietly
fall back to a pid. The criterion only locks the shape, so this is a real choice with
a cost either way, not a settled one.

The escaper handles `"` and `\` because those are the two characters that break the
s-expr string the daemon reads. If the daemon's reader later grows other escape
sequences (newlines, control bytes), the escaper has to grow with it or a future
intent will round-trip wrong. This slice scopes the escaper to exactly what the
current reader needs, and the round-trip test is what would catch a drift.

`main/1`'s halt behavior is proven by reading the source, not by running it. That is
weaker than an executed assertion — it confirms the wiring is written, not that a
real `halt` produced the right OS status. The honest reason is that running `halt/1`
inside the gate would take the test runner down with it. CLI.6 (the installed binary)
is where an end-to-end run of the real entrypoint becomes possible.
