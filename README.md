# Soma

Soma is an Erlang/OTP-native agent runtime. It proves one idea:

```text
An agent run is a supervised OTP process tree, not a function that loops over
tool calls.
```

Erlang/OTP provides the execution semantics — timeouts, cancellation, monitoring,
crash isolation — while the step list only says *what* to run. The full rationale
and design live in **[docs/design.md](docs/design.md)**, the project's north star.

The Lisp-flavored DSL is Soma's first **agent intent language**: a constrained
syntax for an agent to describe bounded operational intent. Lisp is not the
runtime and the compiler does not evaluate arbitrary Lisp; the hard boundary is
`DSL -> validated step list -> OTP execution`.

**Status — built and green on `main`** (EUnit 110, Common Test 134, Erlang/OTP 29).
The runtime executes sequential runs, isolates failures, and runs both in-BEAM
Erlang tools and external one-shot CLI tools — each proven under test, asserting
*process survival*, not just return values. An LFE DSL compile-only layer
(v0.3) is built and proven. The **`soma_actor` agent-entity layer** (v0.4) is
built on top of the execution core: a long-lived `gen_statem` that takes
messages, creates tasks, runs them through `soma_run`, and returns results —
fixed-rule decisions, no real LLM yet. A self-contained macOS arm64 release is
built and verified; the Linux x86_64 / arm64 artifacts are the one remaining
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

![Soma supervision tree — soma_sup (apps/soma_runtime) supervises the in-memory event store, the tool registry, a session supervisor over the long-lived soma_agent_session (gen_server), and a run supervisor over soma_run (a per-run gen_statem) which spawns a disposable soma_tool_call worker per tool call; a cli tool's external OS process hangs off that worker. Below it, a separate app apps/soma_actor has its own soma_actor_sup over the soma_actor agent entity (gen_statem), which starts runs directly under soma_run_sup.](docs/diagrams/supervision-tree.svg)

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
- **`soma_actor`** (`gen_statem`, the v0.4 agent-entity layer) is a separate
  OTP app (`apps/soma_actor`) that sits *above* the execution core — one-way
  dependency, the runtime never imports it. Its own root supervisor
  (`soma_actor_sup`, `simple_one_for_one`) starts actor instances. An actor
  takes work as a **message** (`send/2`, `ask/3`), mints `task_id` /
  `correlation_id`, and on a steps envelope starts a `soma_run` **directly**
  (it owns the run as `session_pid => self()`, no session in its path). It
  observes the run's terminal message, records the result, and survives a
  failed / timed-out / cancelled run as data — the actor never executes tool
  logic itself.

![soma_run state machine — executing and waiting_tool form the step loop (a successful tool result advances to the next step); the explicit terminal states are completed, failed, timeout, and cancelled.](docs/diagrams/run-states.svg)

## Quick start

Prerequisites: Erlang/OTP 29 and rebar3.

```bash
rebar3 compile
rebar3 eunit && rebar3 ct      # 110 EUnit + 134 Common Test, all green
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

### Drive an actor (v0.4)

The `soma_actor` layer takes a message and runs it for you. `ask/3` blocks for
the result:

```erlang
application:ensure_all_started(soma_actor).
{ok, Store} = soma_event_store:start_link().
{ok, A} = soma_actor_sup:start_actor(#{actor_id => <<"a1">>,
                                       model_config => #{}, tool_policy => #{},
                                       event_store => Store}).
soma_actor:ask(A, #{type => <<"chat">>, payload => #{},
                    steps => [#{id => s1, tool => echo,
                                args => #{value => <<"hello">>}}]}, 5000).
%% => {ok, #{s1 => #{value => <<"hello">>}}}
```

`examples/soma_actor_demo.erl` walks the rest — `send` + polling, the
`by_correlation/2` event chain, real mid-run cancellation, and surviving a
failure (`c("examples/soma_actor_demo").` in the shell). The full actor API is
in [docs/usage.md](docs/usage.md).

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
- **An LFE DSL compile-only layer** (`soma_lfe`). `soma_lfe:compile(Source, #{})` parses a small Lisp-flavored grammar into the exact step-list maps `start_run/2` accepts — no processes started, no events emitted, no runtime dependency. This is a constrained intent language for agents and humans to author runs; it is not a Lisp evaluator. Compilation returns `{ok, #{run => #{steps => Steps}}}` or `{error, [Diagnostic]}` with structured diagnostic codes. See [docs/lfe-dsl.md](docs/lfe-dsl.md).
- **An agent-entity layer** (`soma_actor`, v0.4). A long-lived `gen_statem`
  takes a message envelope through `send/2` (async, returns `{ok, TaskId}`) or
  `ask/3` (blocks the caller for the result), mints `task_id` / `correlation_id`,
  and emits `actor.message.received` / `actor.task.accepted`. A fixed rule —
  envelope carries `steps` → validate → start a `soma_run` the actor owns —
  drives execution; on the run's terminal message the actor records the result
  (`actor.result.created` / `actor.task.completed`) or the failure
  (`actor.task.failed` / `actor.task.cancelled`) and stays alive. Results are
  available three ways: `ask/3` reply, `get_task_status/2` + `get_task_result/2`
  polling, and the event stream — `soma_event_store:by_correlation/2` returns the
  whole task chain (actor *and* run events) under one `correlation_id`.
  `cancel/2` cancels a task's active run for real (the tool worker is killed).
  No real LLM, planner, or policy gate yet — those are v0.5.
- **A mandatory event log** (in-memory) records the whole run, each event
  carrying 8 fields (`event_id, timestamp, session_id, run_id, step_id,
  tool_call_id, event_type, payload`): `session.started -> run.accepted ->
  run.started ->` per step `step.started -> tool.started -> tool.succeeded ->
  step.succeeded -> ... -> run.completed` (or `run.failed` / `run.timeout` /
  `run.cancelled`). Actor-layer events add `actor.*` types and an
  `actor_id` / `task_id` / `correlation_id` extension; a `soma_run` started by an
  actor stamps the `correlation_id` onto every run event too.

![A tool call crosses a process boundary — soma_run spawns and monitors a soma_tool_call worker; the worker runs an erlang_module tool in-BEAM or a cli tool through a port, then sends the result back as a message. On timeout or cancel the run kills the worker, and a cli tool's external OS process with it.](docs/diagrams/tool-call.svg)

Every guarantee is proven by a test that asserts **process survival, not just
return values**. The runtime proofs live in `apps/soma_runtime/test/`; the full
proof→test map (a `cli` tool succeeds through the real layers, a hanging or
cancelled `cli` run leaves no live external process, a CLI failure fails the run
not the session, …) is **[docs/contracts/v0.2-test-contract.md](docs/contracts/v0.2-test-contract.md)**.

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
tools, real timeout/cancellation, normalized failures, the event log, a
compile-only LFE DSL layer (`soma_lfe`), the `soma_actor` agent-entity skeleton
(fixed-rule decisions, no real LLM), and a self-contained release.

Out of scope (later roadmap layers, see **[docs/roadmap.md](docs/roadmap.md)**):
a real LLM planner and policy gate (v0.5), MCP, DAG parallelism, distributed
Erlang, and persistent run resume.

## Docs

**Reference**

- **[docs/design.md](docs/design.md)** — north star: thesis, runtime shape, and
  the non-negotiable constraints. Where the implementation refined the design
  (e.g. step iteration lives inside `soma_run`, not a separate `soma_step`
  process), this README and the code are authoritative.
- **[docs/usage.md](docs/usage.md)** — API reference: starting the runtime,
  registering tools, starting runs, reading events, cancellation.
- **[docs/tool-manifest.md](docs/tool-manifest.md)** — tool manifest contract:
  the shape of a tool entry, which adapter runs it, and the cli execution
  protocol.
- **[docs/lfe-dsl.md](docs/lfe-dsl.md)** — LFE DSL: syntax reference,
  step-list contract, `from_step` forms, diagnostic codes, and explicit
  non-goals. The `soma_lfe` app is a compile-only layer with no runtime
  dependency on `soma_runtime`.
- **[docs/release.md](docs/release.md)** — building and running the release.
- **[docs/roadmap.md](docs/roadmap.md)** — future layers beyond the current
  build.

**Test contracts**

- **[docs/contracts/v0.2-test-contract.md](docs/contracts/v0.2-test-contract.md)**
  — process-behaviour proofs for manifests and the CLI adapter: each property
  mapped to the suite and test case that proves it.
- **[docs/contracts/v0.3-test-contract.md](docs/contracts/v0.3-test-contract.md)**
  — process-behaviour proofs for the LFE DSL compiler layer: compile-only
  boundary, validation, parser, and runtime integration.
- **[docs/contracts/v0.4-test-contract.md](docs/contracts/v0.4-test-contract.md)**
  — process-behaviour proofs for the `soma_actor` agent-entity layer: actor
  start, task creation, run integration, result model, correlation lookup,
  survival under failure / crash, and cancellation. The twelve in-scope proofs
  (P1–P11, P15) are green; P12–P14 are deferred to v0.5.

**Chinese docs**

- **[docs/zh/what-is-soma.zh.md](docs/zh/what-is-soma.zh.md)** — overview of
  Soma, the `soma_actor` agent entity, and the execution path.
- **[docs/zh/soma-actor.zh.md](docs/zh/soma-actor.zh.md)** — soma_actor complete
  design: actor entity, message-driven trigger, actor loop, decision frame,
  policy gate, LLM call, result model, event contract, memory model, and
  minimum scope. The v0.4 build implements the minimal slice (fixed-rule
  decisions); the LLM planner and policy gate are v0.5.
- **[docs/zh/erlang-otp-primer.zh.md](docs/zh/erlang-otp-primer.zh.md)** —
  Erlang/OTP primer (BEAM, process, mailbox, gen_server, gen_statem, supervisor,
  port, release) for readers unfamiliar with Erlang.
