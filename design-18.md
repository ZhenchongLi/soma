# [cc] v0.2: implement one-shot CLI adapter happy path

## Current state

The v0.2 manifest already knows about `cli` tools on paper. `soma_tool_manifest:normalize/1`
validates a `cli` manifest (an `executable` plus an `argv` list, with a shell
command string rejected) and `soma_tool_registry:resolve_descriptor/1` hands a
tool's descriptor back whole. But nothing runs a `cli` tool.

Three things only know about `erlang_module` tools:

- `soma_tool_registry` (the gen_server) seeds only the five `erlang_module`
  built-ins from `?BUILTIN_MODULES`. Its declared `descriptor()` type even pins
  `adapter := erlang_module`. The pure `register/3` accepts any descriptor, but
  the gen_server exposes no runtime call to add one.
- `soma_run.erl` resolves a step's tool, then matches `{ok, #{module := Module}}`
  and only knows how to start a worker around a module. A descriptor without a
  `module` key would badmatch.
- `soma_tool_call:run/1` reads `module` out of its opts and calls
  `Module:invoke(Input, Ctx)`. It has no other way to run anything.

So a step naming a `cli` tool cannot even be registered, let alone executed. The
`docs/tool-manifest.md` `cli` section stops at `executable` + `argv` and says the
execution protocol is left to this issue.

## Approach

Target state: register a `cli` tool in the running registry, run a step that
names it through the normal session/run/tool-call layers, launch the external
program with executable + argv through an Erlang port (no shell), feed the step's
resolved input to the program, and record the program's stdout as the step's
output when it exits zero.

Four decisions.

### 1. How a `cli` tool gets into the running registry

Add a runtime register call to the `soma_tool_registry` gen_server, for example
`register_tool/1` taking a normalized descriptor and keying it by the
descriptor's `name`. It normalizes through `soma_tool_manifest:normalize/1` first,
so a bad manifest is rejected before it lands in the seed map, the same rule the
seed build already follows.

This is the smallest change that gives a test the observable outcome the first
criterion asks for: register a `cli` manifest, then resolve it by name. The pure
`register/3` stays as is. The gen_server's `descriptor()` type widens to allow the
`cli` shape (adapter `cli`, `executable`, `argv`) alongside the `erlang_module`
shape.

The alternative — seeding a fixed `cli` tool at boot the way the five built-ins
are seeded — is rejected. There is no built-in `cli` tool to seed in v0.1, and
issue #22 is the one that packages sample `cli` tools. A runtime register call is
also what a CT suite needs to register its own test helper.

### 2. How the worker tells a `cli` call apart from an `erlang_module` one

`soma_run` reads the resolved descriptor and branches on `adapter`. For an
`erlang_module` descriptor it passes `module` to the worker as it does today. For
a `cli` descriptor it passes the `executable`, the `argv`, and the resolved input
to the worker instead. The worker owns the port. That keeps the kill path #19
needs simple later: killing the worker kills the port and the OS process with it.

`soma_tool_call:run/1` branches on which opts it received. With a `module` it runs
the in-BEAM path unchanged. With an `executable` and `argv` it opens a port, runs
the program, collects stdout, and replies with the same
`{tool_result, ToolCallId, self(), {ok, Output}}` shape the run already waits on.
The run does not change how it handles the reply — a `cli` success and an
`erlang_module` success arrive identically.

### 3. The input channel (the protocol this issue writes down)

The step's resolved input reaches the program as a trailing argv argument, not on
stdin. Reason: an Erlang port cannot half-close the child's stdin, so a helper
that blocks reading stdin until EOF would hang waiting for an EOF the runtime
cannot send. Passing the input as an argument is deterministic and cannot hang.

So the worker launches `executable` with `argv ++ [InputArg]`, where `InputArg` is
the resolved step input rendered as one argument. The program reads its input from
that last argument, does its work, and writes its result to stdout.

This is the protocol that goes into `docs/tool-manifest.md`: input arrives as the
final argv argument, stdout is captured as the step output, exit status 0 means
success.

The honest downside is in Risks below.

### 4. Capturing stdout and exit status

The worker opens the port with `exit_status` and a binary/stream mode, accumulates
the program's stdout, and waits for the `{Port, {exit_status, 0}}` message. On exit
0 it replies `{ok, Stdout}` with the collected bytes as the output. Non-zero exit,
stderr, and output bounds are out of scope (issues #20 and #21), so this happy path
assumes exit 0.

### Test helper

The CT suite needs a real `cli` program. A tiny script written to a temp path at
test setup is enough: it reads its last argv argument, transforms it (for example
uppercases it, or wraps it), and prints the result to stdout, then exits 0. It must
read from argv and terminate on its own — never block on stdin — matching the
chosen protocol. The argv-metacharacter criterion needs the helper to echo back one
chosen argument verbatim so the test can assert a `;` or `$(...)` argument arrived
literally.

## Acceptance criteria → tests

The CLI runtime tests are new and belong in soma_runtime CT, because they drive a
real run through session/run/tool-call. A new suite
`apps/soma_runtime/test/soma_cli_adapter_SUITE.erl` holds them. The doc criterion
is an EUnit test in soma_tools next to the existing doc tests. The registry
runtime-register criterion is an EUnit test in soma_tools.

### Criterion 1 — a registered `cli` manifest resolves to a `cli` descriptor
- Call chain: test registers a `cli` manifest through the new
  `soma_tool_registry:register_tool/1` on the running gen_server →
  `soma_tool_registry:resolve_descriptor/1` → gen_server `lookup`
- Test entry: `soma_tool_registry:register_tool/1` then `resolve_descriptor/1` on
  the booted runtime (no layer bypassed)
- Test: `test_cli_manifest_resolves_to_cli_descriptor` in
  `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 2 — a run naming a registered `cli` tool reaches `run.completed`
- Call chain: `soma_agent_session:start_run` → `soma_run_sup:start_run` →
  `soma_run` executing → `resolve_descriptor` (cli branch) →
  `soma_tool_call:start` → port launch → reply → `soma_run` records
  `run.completed`
- Test entry: `soma_agent_session:start_run` (the real run entry point; nothing
  bypassed)
- Test: `test_cli_run_reaches_completed` in `soma_cli_adapter_SUITE.erl`

### Criterion 3 — the `cli` invocation runs in its own worker pid, distinct from the run
- Call chain: `soma_agent_session:start_run` → `soma_run` → `soma_tool_call:start`
  (spawns the worker) → `tool.started` / `tool.succeeded` carry that worker pid
- Test entry: `soma_agent_session:start_run`; the test reads the worker pid off
  the `tool.started` and `tool.succeeded` events and compares to the `soma_run`
  pid read from `soma_run_sup`
- Test: `test_cli_tool_call_has_distinct_pid` in `soma_cli_adapter_SUITE.erl`

### Criterion 4 — an argv shell metacharacter reaches the program as one literal argument
- Call chain: `soma_agent_session:start_run` → `soma_run` (cli branch passes argv
  through) → `soma_tool_call` opens the port with executable + argv → helper echoes
  the metacharacter argument back on stdout
- Test entry: `soma_agent_session:start_run`; the step's `argv` carries an element
  like `";"` or `"$(echo pwned)"`, and the test asserts the recorded step output
  contains that exact literal, proving no shell expanded it
- Test: `test_cli_argv_metacharacter_is_literal` in `soma_cli_adapter_SUITE.erl`

### Criterion 5 — stdout is recorded as the step output on `step.succeeded` at exit 0
- Call chain: `soma_tool_call` port collects stdout and the `{exit_status, 0}`
  message → replies `{ok, Stdout}` → `soma_run` records `step.succeeded` with
  `payload.output`
- Test entry: `soma_agent_session:start_run`; the test reads the `step.succeeded`
  payload output from the event store and asserts it equals the helper's printed
  stdout
- Test: `test_cli_stdout_is_step_output` in `soma_cli_adapter_SUITE.erl`

### Criterion 6 — a `cli` step emits `tool.started`, then `tool.succeeded`, then `step.succeeded`
- Call chain: `soma_agent_session:start_run` → `soma_run` emits the three events in
  that order around the worker reply
- Test entry: `soma_agent_session:start_run`; the test reads the run's event trail
  and asserts the index order of the three event types for the cli step
- Test: `test_cli_step_event_order` in `soma_cli_adapter_SUITE.erl`

### Criterion 7 — multi-step run flows data into and out of the `cli` program via `from_step`
- Call chain: `soma_agent_session:start_run` with three steps → step one (an
  `erlang_module` tool) produces output → step two (the `cli` helper) takes step
  one's output as input through `from_step`, transforms it, prints to stdout → step
  three takes the cli step's stdout through `from_step`
- Test entry: `soma_agent_session:start_run`; the test asserts step three's
  recorded output reflects the cli helper's transform applied to step one's output,
  proving run data went into the external process and came back through the normal
  step wiring
- Test: `test_cli_from_step_round_trip` in `soma_cli_adapter_SUITE.erl`

### Criterion 8 — `docs/tool-manifest.md` documents the v0.2 `cli` execution protocol
- Call chain: none (direct source-file read)
- Test entry: an EUnit test reads `docs/tool-manifest.md` and asserts it states the
  input channel (input delivered as the final argv argument), that stdout is
  captured and recorded as the step output, and that exit status 0 means success —
  the same read-the-doc style the existing manifest doc tests use
- Test: `test_manifest_doc_describes_cli_execution_protocol` in
  `apps/soma_tools/test/soma_tool_manifest_doc_tests.erl`

### Criterion 9 — existing soma_runtime and soma_tools CT and EUnit suites stay green
- Call chain: none (the whole existing suite run is the assertion)
- Test entry: `rebar3 eunit && rebar3 ct` — no new test; the gate is that the
  registry type widening, the `soma_run` branch, and the `soma_tool_call` branch do
  not break the `erlang_module` path the existing suites cover
- Test: existing `soma_run_happy_path_SUITE`, `soma_run_failure_SUITE`,
  `soma_tool_manifest_tests`, `soma_tool_registry_tests`,
  `soma_tool_manifest_doc_tests` stay green

## Risks & trade-offs

Passing the input as a trailing argv argument is the safe choice against hanging,
but it is not how a real filter program reads input. A real `grep` or `jq` reads
stdin, and argv has a length limit and is visible in the process table. This issue
picks argv on purpose because the port cannot send EOF on stdin and a stdin-reading
helper would hang, which the issue calls out. The protocol written into the doc is
honest about being the v0.2 happy-path channel, not the final filter model. If a
later issue needs real stdin streaming it will need a different port setup, and the
doc will have to change with it.

The registry's `descriptor()` type widens to a union of the `erlang_module` and
`cli` shapes. `soma_tool_registry:resolve/1` (the bare-module path) still reads
`module` out of a descriptor, so calling `resolve/1` on a `cli` name would fail its
match. That is fine for this issue — the run uses `resolve_descriptor/1` and
branches on `adapter` — but it is a sharp edge: `resolve/1` is now only valid for
`erlang_module` tools. Worth a comment so a later caller does not reach for
`resolve/1` on a `cli` name.

Killing the OS process on cancel or timeout is #19, not here. The worker owns the
port so that kill path stays simple later, but this issue does not test it, and a
cli step with no per-step timeout would wait unbounded if the program hung. The
happy-path helper exits on its own, so this does not bite here.
