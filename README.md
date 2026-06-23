# Soma

Soma is an Erlang/OTP-native agent runtime. It proves one idea:

```text
An agent run is a supervised OTP process tree, not a function that loops over
tool calls.
```

Erlang/OTP provides the execution semantics — timeouts, cancellation, monitoring,
crash isolation — while the step list only says *what* to run. The full rationale
and design spec live in **[docs/design.md](docs/design.md)**, the project's north
star.

**Status — v0.1 is built.** The runtime executes sequential runs, isolates
failures, and proves it under test: all ten required process-behaviour proofs
pass (EUnit 21, Common Test 28, green on `main`), plus a self-contained macOS
release. Remaining for the full v0.1 release scope: the Linux x86_64 / arm64
artifacts.

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
processes, mailboxes, supervision, `gen_statem`, monitors, timers — instead of
reimplementing weaker versions of them in a language that wasn't built for it.
See [docs/design.md](docs/design.md) for the full thesis.

## Architecture

```text
soma_sup
  ├── soma_event_store        in-memory audit log (gen_server)
  ├── soma_tool_registry      tool name → module
  ├── soma_session_sup → soma_agent_session   long-lived session (gen_server)
  └── soma_run_sup     → soma_run              per-run state machine (gen_statem)
                            └── soma_tool_call  one tool invocation, then dies
```

- **`soma_agent_session`** (`gen_server`) owns a `session_id`, accepts run
  requests, starts runs, tracks them, and **survives any run's failure**. It
  never executes tools itself.
- **`soma_run`** (`gen_statem`) owns one run. Terminal states are explicit:
  `completed | failed | timeout | cancelled`. It iterates the steps internally
  (its `executing` / `waiting_tool` states are the step cursor) and starts each
  tool call as a **monitored** worker.
- **`soma_tool_call`** runs exactly one tool invocation in its own process and
  exits. Every tool call crosses a process boundary; a tool crash arrives at the
  run as a monitor `'DOWN'` — **data for the run, not a crash of the session**.

## Quick start

Prerequisites: Erlang/OTP 29 and rebar3.

```bash
rebar3 compile
rebar3 eunit && rebar3 ct      # 21 EUnit + 28 Common Test, all green
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

## What v0.1 does

- **Sequential steps.** A step is `#{id, tool, args, timeout_ms}`. `args` may
  carry `from_step => StepId` (feed a prior step's whole output in) or a field
  like `bytes => {from_step, StepId}` (feed it into one field).
- **A process per tool call.** Tool results come back to the run as messages;
  the run owns all state.
- **Real failure semantics.** A tool returning `{error, _}` fails the run; a tool
  process that crashes is absorbed and the session survives; a hanging tool is
  killed by a per-step timeout; a run can be cancelled mid-flight
  (`SessionPid ! {cancel_run, RunId}`); and the session keeps serving — it runs
  again after any terminal state.
- **A mandatory event log** (in-memory) records the whole run, each event
  carrying 8 fields (`event_id, timestamp, session_id, run_id, step_id,
  tool_call_id, event_type, payload`): `session.started -> run.accepted ->
  run.started ->` per step `step.started -> tool.started -> tool.succeeded ->
  step.succeeded -> ... -> run.completed` (or `run.failed` / `run.timeout` /
  `run.cancelled`).

The ten proofs assert **process survival, not just return values**; they live in
`apps/soma_runtime/test/soma_run_happy_path_SUITE.erl` and
`soma_run_failure_SUITE.erl`.

## Tools

Built-in v0.1 tools (registered under atom names): `echo`, `sleep`, `fail` (for
tests — error and crash modes), `file_read`, `file_write` (sandboxed under a
`root`). A tool is a behaviour with `describe/0` and `invoke/2`; its spec
declares an `effect` (`identity | reader | state`), `idempotent`, and
`timeout_ms`. External tools use executable + args, never shell strings.

## Release

```bash
rebar3 as prod tar
```

builds a self-contained release that bundles ERTS and runs without Erlang
installed → `_build/prod/rel/soma/soma-0.1.0.tar.gz`. macOS arm64 is built and
verified; the Linux x86_64 / arm64 artifacts build the same `prod` profile on
those hosts. See **[docs/release.md](docs/release.md)**.

## Scope (v0.1)

In scope: the runtime, the failure semantics, the event log, and a self-contained
release. Out of scope: DAG parallelism, distributed Erlang, complex planning,
retries beyond none, and any hard dependency on a real LLM.

## Docs

- **[docs/design.md](docs/design.md)** — the north star: thesis, runtime shape,
  non-negotiable constraints, and the full v0.1 spec. Where the implementation
  refined the design (e.g. step iteration lives inside `soma_run` rather than a
  separate `soma_step` process), this README and the code are authoritative.
- **[docs/release.md](docs/release.md)** — building and running the release.
- **[docs/roadmap.md](docs/roadmap.md)** — post-v0.1 ideas.
```
