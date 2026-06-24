# Soma

Soma is an Erlang/OTP-native agent runtime. It proves one idea:

```text
An agent run is a supervised OTP process tree, not a function that loops over
tool calls.
```

Erlang/OTP provides the execution semantics — timeouts, cancellation, monitoring,
crash isolation — while the step list only says *what* to run. The full rationale
and design live in **[docs/design.md](docs/design.md)**, the project's north star.

**Status — built and green on `main`** (EUnit 72, Common Test 61, Erlang/OTP 29).
The runtime executes sequential runs, isolates failures, and runs both in-BEAM
Erlang tools and external one-shot CLI tools — each proven under test, asserting
*process survival*, not just return values. A self-contained macOS arm64 release
is built and verified; the Linux x86_64 / arm64 artifacts are the one remaining
packaging task.

## The idea

Soma is built on the **actor model**: every session, run, and tool call is an
*actor* — an isolated process with a private mailbox that talks only by messages.
Erlang is the canonical actor runtime; OTP then layers supervision and monitoring
on top, turning plain actors into *actors that fail safely*. That second layer is
the point.

Agent systems fail in operational ways: model calls hang, tools time out,
external programs crash, sessions stay alive for a long time, cancellation has to
be real, and every run needs an audit trail — and one run's failure must not
poison the whole session. Erlang/OTP was built for exactly this class of problem
(telecom-grade failure isolation). Soma uses those primitives directly —
processes, mailboxes, supervision, `gen_statem`, monitors, timers, ports —
instead of reimplementing weaker versions of them in a language that wasn't built
for it. See [docs/design.md](docs/design.md) for the full thesis.

## Architecture

![Soma supervision tree — soma_sup supervises the in-memory event store, the tool registry, a session supervisor over the long-lived soma_agent_session (gen_server), and a run supervisor over soma_run (a per-run gen_statem) which spawns a disposable soma_tool_call worker per tool call; a cli tool's external OS process hangs off that worker.](docs/diagrams/supervision-tree.svg)

- **`soma_agent_session`** (`gen_server`) owns a `session_id`, accepts run
  requests, starts runs, tracks them, and **survives any run's failure**. It
  never executes tools itself.
- **`soma_run`** (`gen_statem`) owns one run. Terminal states are explicit:
  `completed | failed | timeout | cancelled`. It iterates the steps internally
  (its `executing` / `waiting_tool` states are the step cursor) and starts each
  tool call as a **monitored** worker.
- **`soma_tool_call`** runs exactly one tool invocation in its own process and
  exits. It dispatches on the tool's adapter: an `erlang_module` tool runs
  in-BEAM via `invoke/2`; a `cli` tool launches an external executable through a
  port. Every tool call crosses a process boundary; a tool crash arrives at the
  run as a monitor `'DOWN'` — **data for the run, not a crash of the session**.

![soma_run state machine — executing and waiting_tool form the step loop (a successful tool result advances to the next step); the explicit terminal states are completed, failed, timeout, and cancelled.](docs/diagrams/run-states.svg)

## Quick start

Prerequisites: Erlang/OTP 29 and rebar3.

```bash
rebar3 compile
rebar3 eunit && rebar3 ct      # 72 EUnit + 61 Common Test, all green
```

Drive a run in the shell:

```bash
rebar3 shell
```

```erlang
{ok, S} = soma_agent_session:start_link(#{}).
{ok, RunId} = soma_agent_session:start_run(S, [
    #{id => greet, tool => echo, args => #{value => <<"hello">>}}
]).
soma_agent_session:get_status(S).
%% => #{session_id => <<"sess-1">>, runs => #{<<"run-1">> => completed}}
```

### The demo: `file_read -> echo -> file_write`

```erlang
file:make_dir("/tmp/somademo"), file:write_file("/tmp/somademo/in.txt", <<"hi soma">>).
{ok, S} = soma_agent_session:start_link(#{}).
Steps = [#{id => read,  tool => file_read,  args => #{path => <<"in.txt">>,  root => "/tmp/somademo"}},
         #{id => echo,  tool => echo,       args => #{from_step => read}},
         #{id => write, tool => file_write, args => #{path => <<"out.txt">>, root => "/tmp/somademo", bytes => {from_step, echo}}}].
{ok, _RunId} = soma_agent_session:start_run(S, Steps).
file:read_file("/tmp/somademo/out.txt").   %% => {ok, <<"hi soma">>}
```

A run executes asynchronously; `get_status/1` reflects its terminal status once
it finishes.

## What it does

- **Sequential steps.** A step is `#{id, tool, args, timeout_ms}`. `args` may
  carry `from_step => StepId` (feed a prior step's whole output in) or a field
  like `bytes => {from_step, StepId}` (feed it into one field).
- **A process per tool call.** Tool results come back to the run as messages; the
  run owns all state. Each invocation runs in its own `soma_tool_call` worker.
- **Tool manifests + a descriptor registry.** A tool declares itself with a
  manifest (a data map) validated by `soma_tool_manifest:normalize/1`; a manifest
  missing a required field is rejected and never resolves. `soma_tool_registry`
  holds the normalized descriptors, and a run resolves a tool to its descriptor —
  which names the **adapter** that runs it.
- **In-BEAM and external CLI tools.** An `erlang_module` tool runs `invoke/2` in
  the BEAM. A `cli` tool runs an external executable once, through a port
  (executable + argv, **never a shell string**), in its own worker: the step
  input is delivered as the final argv argument, stdout is captured as the step
  output, and exit status 0 is success — with a minimal environment (only `PATH`)
  and a fixed working directory.
- **Real failure semantics.** A tool returning `{error, _}` fails the run; a tool
  process that crashes is absorbed and the session survives; a hanging tool is
  killed by a per-step timeout — and for a `cli` tool the **external OS process is
  torn down too** (lifecycle teardown), not just the BEAM worker; a run can be
  cancelled mid-flight (`SessionPid ! {cancel_run, RunId}`), which also stops the
  external process. A CLI tool's operational failures — a missing/unrunnable
  executable, a nonzero exit, oversized output — are **failure normalization**
  into named, bounded `{error, _}` data. Through all of it the session keeps
  serving: it runs again after any terminal state.
- **A mandatory event log** (in-memory) records the whole run, each event
  carrying 8 fields (`event_id, timestamp, session_id, run_id, step_id,
  tool_call_id, event_type, payload`): `session.started -> run.accepted ->
  run.started ->` per step `step.started -> tool.started -> tool.succeeded ->
  step.succeeded -> ... -> run.completed` (or `run.failed` / `run.timeout` /
  `run.cancelled`).

![A tool call crosses a process boundary — soma_run spawns and monitors a soma_tool_call worker; the worker runs an erlang_module tool in-BEAM or a cli tool through a port, then sends the result back as a message. On timeout or cancel the run kills the worker, and a cli tool's external OS process with it.](docs/diagrams/tool-call.svg)

Every guarantee is proven by a test that asserts **process survival, not just
return values**. The runtime proofs live in `apps/soma_runtime/test/`; the full
proof→test map (a `cli` tool succeeds through the real layers, a hanging or
cancelled `cli` run leaves no live external process, a CLI failure fails the run
not the session, …) is **[docs/v0.2-test-contract.md](docs/v0.2-test-contract.md)**.

## Tools

A tool is a behaviour with `describe/0` and `invoke/2`; its spec declares an
`effect` (`identity | reader | state`), `idempotent`, and `timeout_ms`, and it
registers through a manifest naming its adapter. Built-in tools (in-BEAM,
`erlang_module` adapter): `echo`, `sleep`, `fail` (for tests — error and crash
modes), `file_read`, `file_write` (sandboxed under a `root`). External tools use
the `cli` adapter — executable + argv, never shell strings, with explicit `argv`,
`env`, and `cwd` handling; a packaged sample helper ships at
`apps/soma_tools/priv/cli/soma_sample_upper`. The manifest shape and the cli
execution protocol are in **[docs/tool-manifest.md](docs/tool-manifest.md)**.

## Release

```bash
rebar3 as prod tar
```

builds a self-contained release that bundles ERTS and runs without Erlang
installed → `_build/prod/rel/soma/soma-0.1.0.tar.gz`. macOS arm64 is built and
verified; the Linux x86_64 / arm64 artifacts build the same `prod` profile on
those hosts and are the remaining packaging work. See
**[docs/release.md](docs/release.md)**.

## Scope

In scope: the runtime, sequential steps, supervised in-BEAM and one-shot CLI
tools, real timeout/cancellation, normalized failures, the event log, and a
self-contained release.

Out of scope (later roadmap layers, see **[docs/roadmap.md](docs/roadmap.md)**):
an LFE DSL, MCP, an LLM planner, DAG parallelism, distributed Erlang, and
persistent run resume.

## Docs

- **[docs/design.md](docs/design.md)** — the north star: thesis, runtime shape,
  and the non-negotiable constraints. Where the implementation refined the design
  (e.g. step iteration lives inside `soma_run` rather than a separate `soma_step`
  process), this README and the code are authoritative.
- **[docs/tool-manifest.md](docs/tool-manifest.md)** — the tool manifest
  contract: the shape of a tool entry, which adapter runs it, and the cli
  execution protocol.
- **[docs/v0.2-test-contract.md](docs/v0.2-test-contract.md)** — the
  process-behaviour test contract for manifests and the CLI adapter: each proof
  mapped to the suite and case that proves it.
- **[docs/release.md](docs/release.md)** — building and running the release.
- **[docs/roadmap.md](docs/roadmap.md)** — the future layers beyond the current
  build.
