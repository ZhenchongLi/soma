# [cc] Tool runtime: soma_tool behaviour, registry, and v0.1 tools

## Current state

The umbrella has three apps. Only `soma_event_store` has code: a `gen_server`
in-memory store with a test suite. `soma_tools` exists as a bare app
(`apps/soma_tools/src/soma_tools.app.src`) with no source modules. Nothing
defines what a tool is yet, so a run has no contract to call against and no way
to turn a step's tool name into a module.

This issue fills the `soma_tools` app with the tool layer the execution core
will sit on top of: the behaviour, the registry, and the five v0.1 tools. We
call `invoke/2` directly here. The process boundary, supervision wiring, and
timeout enforcement are a later issue, so none of that appears in this code.

## Approach

Add to `apps/soma_tools/src/`:

- `soma_tool.erl` — the behaviour. Declares `describe/0` and `invoke/2` as
  callbacks and exports the types the callbacks name (`spec/0`, `input/0`,
  `ctx/0`, `output/0`, `error/0`). No logic, just the contract.
- `soma_tool_registry.erl` — a name-to-module map. Looking up a registered
  name returns `{ok, Module}`. A miss returns `{error, not_found}`. It can also
  list every registered name.
- `soma_tool_echo.erl`, `soma_tool_sleep.erl`, `soma_tool_fail.erl`,
  `soma_tool_file_read.erl`, `soma_tool_file_write.erl` — the five tools, each
  implementing the behaviour.

Decisions worth pinning down:

**Registry shape.** The registry holds a plain map of `name => module`. The
issue says wiring it into `soma_sup` is out of scope, so it is not a process
yet. I make it a pure module: `register/3` takes a map, a name, and a module
and returns the updated map; `lookup/2` and `names/1` read from a map the
caller passes in. The execution core can later wrap this in whatever owns the
state (a `gen_server` or application env). Keeping it pure now means the tests
need no process and no supervisor. The trade-off is that this module does not
hold state on its own — that is fine, because nothing in this issue needs it
to.

**Sleep return shape.** The open question lets sleep return `ok` or `{ok, _}`.
I pin it to `{ok, Input}` so every non-failing tool has the same
`{ok, Output}` shape. That keeps the run's result handling uniform when the
execution core arrives. The test asserts elapsed time is at least the requested
milliseconds and that the reply matches `{ok, _}`.

**Registry miss shape.** Pinned to `{error, not_found}`.

**fail tool modes.** `fail` reads its mode from the input. Error mode returns
`{error, Reason}` where `Reason` comes from the input (default a fixed atom).
Crash mode raises — an `error(Reason)` exception, not a returned value. The
test for crash mode uses `?assertError` (or a `try`) and checks no value comes
back.

**Sandbox enforcement for file tools.** Both file tools take the sandbox root
from `ctx` and a path from `input`. The path is resolved against the root, then
the result is checked to confirm it still sits under the root after `..`
segments and symlink-free normalization are accounted for. A path that escapes
through `..` or an absolute path pointing outside the root returns `{error, _}`
and never touches the filesystem — the read or write only runs after the path
clears the check. The check is shared logic; I put it in one place so both
tools enforce the same rule. The candidate spot is a small helper inside the
file-read and file-write modules or a tiny shared internal function. Either way
the behaviour is identical: resolve, verify containment, then act.

**describe/0 metadata.** Every tool returns a map with at least `name`,
`effect`, `idempotent`, `timeout_ms`. Effects: `echo` is `identity`, `sleep` is
`identity`, `fail` is `identity`, `file_read` is `reader`, `file_write` is
`state`.

Tests follow the convention the event store set: EUnit, with a
`test_<name>/0` helper and a thin `<name>_test/0` wrapper that calls it. One
test file per concern under `apps/soma_tools/test/`. Splitting by concern keeps
each criterion's test easy to find: behaviour, registry, the simple tools, and
the file tools each get their own suite file.

## Acceptance criteria → tests

### Criterion 1 — soma_tool behaviour declares describe/0 and invoke/2
- Call chain: none (compile-time assertion). A real tool module names
  `-behaviour(soma_tool)` and the compiler checks the callbacks exist.
- Test entry: the test compiles a module that declares
  `-behaviour(soma_tool)` and implements both callbacks, then confirms
  `soma_tool:behaviour_info(callbacks)` lists `{describe,0}` and `{invoke,2}`.
- Test: `test_behaviour_declares_callbacks` in
  `apps/soma_tools/test/soma_tool_tests.erl`

### Criterion 2 — echo returns its input unchanged
- Call chain: caller → `soma_tool_echo:invoke/2`
- Test entry: `soma_tool_echo:invoke/2` (no layer bypassed)
- Test: `test_echo_returns_input` in
  `apps/soma_tools/test/soma_tool_echo_tests.erl`

### Criterion 3 — sleep returns only after the requested delay
- Call chain: caller → `soma_tool_sleep:invoke/2`
- Test entry: `soma_tool_sleep:invoke/2`. The test records a monotonic
  timestamp before and after the call and asserts the gap is at least the
  requested milliseconds, and that the reply matches `{ok, _}`.
- Test: `test_sleep_waits_requested_ms` in
  `apps/soma_tools/test/soma_tool_sleep_tests.erl`

### Criterion 4 — fail in error mode returns {error, Reason}
- Call chain: caller → `soma_tool_fail:invoke/2` with error mode in input
- Test entry: `soma_tool_fail:invoke/2`
- Test: `test_fail_error_mode_returns_error` in
  `apps/soma_tools/test/soma_tool_fail_tests.erl`

### Criterion 5 — fail in crash mode raises instead of returning
- Call chain: caller → `soma_tool_fail:invoke/2` with crash mode in input
- Test entry: `soma_tool_fail:invoke/2`, wrapped in `?assertError` so the
  raised exception is what the test checks. No value is returned.
- Test: `test_fail_crash_mode_raises` in
  `apps/soma_tools/test/soma_tool_fail_tests.erl`

### Criterion 6 — file_read returns the bytes of a file under the sandbox root
- Call chain: caller → `soma_tool_file_read:invoke/2`
- Test entry: `soma_tool_file_read:invoke/2`. The test writes a file under a
  temp sandbox root with `file:write_file`, then reads it through the tool and
  checks the returned bytes match.
- Test: `test_file_read_returns_bytes` in
  `apps/soma_tools/test/soma_tool_file_tests.erl`

### Criterion 7 — write then read the same path returns the written bytes
- Call chain: caller → `soma_tool_file_write:invoke/2` →
  `soma_tool_file_read:invoke/2`
- Test entry: `soma_tool_file_write:invoke/2`, then
  `soma_tool_file_read:invoke/2` on the same sandbox root and path. The test
  asserts the bytes read equal the bytes written.
- Test: `test_file_write_then_read_roundtrips` in
  `apps/soma_tools/test/soma_tool_file_tests.erl`

### Criterion 8 — `..` traversal is rejected and the file is untouched
- Call chain: caller → `soma_tool_file_read:invoke/2` (and
  `soma_tool_file_write:invoke/2`) with a path containing `..`
- Test entry: both file tools, each with a path that climbs out of the root
  through `..`. The test asserts the return matches `{error, _}`. For write it
  also asserts the target file was not created. For read it asserts no file
  outside the root is reached.
- Test: `test_file_dotdot_escape_rejected` in
  `apps/soma_tools/test/soma_tool_file_tests.erl`

### Criterion 9 — absolute path outside the root is rejected and untouched
- Call chain: caller → `soma_tool_file_read:invoke/2` (and
  `soma_tool_file_write:invoke/2`) with an absolute path outside the root
- Test entry: both file tools, each given an absolute path that points outside
  the sandbox root. The test asserts `{error, _}` and that no read or write
  reaches that path.
- Test: `test_file_absolute_outside_root_rejected` in
  `apps/soma_tools/test/soma_tool_file_tests.erl`

### Criterion 10 — registry returns the module for a registered name
- Call chain: caller → `soma_tool_registry:register/3` →
  `soma_tool_registry:lookup/2`
- Test entry: `soma_tool_registry:register/3` to build the map, then
  `soma_tool_registry:lookup/2`. Asserts the result is `{ok, Module}`.
- Test: `test_registry_lookup_hit` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl`

### Criterion 11 — registry returns not-found for an unregistered name
- Call chain: caller → `soma_tool_registry:lookup/2` on a name never registered
- Test entry: `soma_tool_registry:lookup/2`. Asserts `{error, not_found}`.
- Test: `test_registry_lookup_miss` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl`

### Criterion 12 — registry lists every registered name
- Call chain: caller → `soma_tool_registry:register/3` (repeated) →
  `soma_tool_registry:names/1`
- Test entry: `soma_tool_registry:names/1` after registering several tools.
  Asserts the listed names equal the set registered.
- Test: `test_registry_lists_names` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl`

### Criterion 13 — each tool's describe/0 has the four required keys
- Call chain: caller → `<tool>:describe/0` for each of the five tools
- Test entry: `describe/0` on each tool module. Asserts the map has `name`,
  `effect`, `idempotent`, `timeout_ms`, and that `effect` is one of
  `identity`, `reader`, `state`.
- Test: `test_describe_has_required_keys` in
  `apps/soma_tools/test/soma_tool_tests.erl`

## Risks & trade-offs

The registry is a pure module here, not a process. That is a real gap from the
README's supervision tree, which shows `soma_tool_registry` as a child of
`soma_sup`. The execution-core issue has to wrap this state in a process and
own its lifecycle. If that issue expects a process-based registry with a
different function signature, these pure functions get reshaped. I accept that
because the issue explicitly puts the `soma_sup` wiring out of scope, and a
pure map keeps this layer testable without a supervisor.

Sandbox containment is the part most likely to be wrong. Path normalization on
its own does not stop a symlink inside the root from pointing out of it. The
criteria only require rejecting `..` traversal and absolute paths outside the
root, so the tests cover exactly those two. A symlink that escapes the root is
not covered by any criterion and is not handled here. That is a known hole to
close when the file tools harden, not in this issue.
