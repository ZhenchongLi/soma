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
`Lisp at the edge -> validated data -> OTP execution`.

**Status — built and green on `main`** (EUnit 259, Common Test 350, Erlang/OTP 29).
Every layer is proven under test, asserting *process survival*, not just return
values. Full layer-by-layer status: **[docs/roadmap.md](docs/roadmap.md)**.

| Runtime layer (foundation → newest) — all built ✓ | What it adds |
| --- | --- |
| **v0.1–0.2** · Runtime core | supervised runs · timeout / cancel / crash · BEAM + CLI tools |
| **v0.3** · LFE DSL | compile-only Lisp → step lists |
| **v0.4** · Agent entity | `soma_actor` (`gen_statem`): messages → tasks → runs |
| **v0.5** · Decision layer | LLM-call worker · proposals · policy gate · budgets |
| **v0.6** · Durability + observability | `soma_trace` timelines · `disk_log` store, survives restart |
| **v0.7** · Persistent resume | `run.started` journal · read-only reconstruct · resume executor (`resume/3`, fail-safe on non-idempotent in-flight steps) |

The real **OpenAI-compatible LLM provider** path is built (opt-in, off the
gate), including an actor-level planning mode that can parse model text as
`run_steps`, and the packaged **`soma` CLI / daemon** is built: `run` / `ask` /
`status` / `cancel` / `trace` / `stop` over a local Unix socket, Lisp on the
wire, with `bin/soma` distinct from the `bin/somad` node-control script. Still
open: v0.7.5 auto-resume on boot, productizing real-model planning at the CLI /
config surface, effect-aware policy, and the **Linux x86_64 / arm64 release
artifacts** (macOS arm64 is done).

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

![Soma runtime topology: the runtime supervises sessions, runs, tool-call workers, and the event store; actors, LLM-call workers, resume readers, and the local CLI sit around that core while preserving process boundaries.](docs/diagrams/supervision-tree.svg)

The execution core is deliberately small and sequential. **`soma_agent_session`**
(`gen_server`) owns a `session_id`, accepts run requests, starts runs, tracks
terminal status, and **survives any run's failure**. It never executes tools.

**`soma_run`** (`gen_statem`) owns one run: step cursor, prior outputs, timers,
active tool-call worker, cancellation, resume metadata, and event emission.
Terminal states are explicit: `completed | failed | timeout | cancelled`. A
resumed run starts from a reconstructed suffix of the original step list and
emits `run.resumed` rather than re-journaling `run.started`.

**`soma_tool_call`** runs exactly one tool invocation in its own process and
exits. It dispatches on the tool's adapter: an `erlang_module` tool runs in-BEAM
via `invoke/2`; a `cli` tool launches an external executable through a port.
Every tool call crosses a process boundary; a crash or nonzero CLI exit becomes
bounded run data, not a session crash.

The event store is part of the runtime boundary. It is in-memory by default and
can be backed by `disk_log` for durable replay. The same event trail powers
`soma_trace` and persistent resume: `soma_run_resume:reconstruct/2` rebuilds run
progress, `soma_run_resume_plan:plan/2` decides whether replay is safe, and
`soma_run_resume_executor:resume/3` starts the resumed run under `soma_run_sup`
or fails clearly when an in-flight stateful step is unsafe to repeat.

**`soma_actor`** (`gen_statem`) is the long-lived agent entity above the
execution core. It receives messages through `send/2` and `ask/3`, owns
`task_id` / `correlation_id`, starts LLM-call workers and runs, applies proposal
normalization, policy, and budget checks, and records task results. It starts
owned `soma_run` processes directly under `soma_run_sup`, observes their terminal
messages, and treats failure, timeout, cancellation, rejection, and budget
exhaustion as task data.

The local daemon and packaged CLI sit at the edge. `soma_cli_server` exposes the
actor/runtime path over a local Unix socket with Lisp on the wire, while
`bin/soma` is the user-facing task command (`run`, `ask`, `status`, `trace`,
`cancel`, `stop`, `daemon`). The release node-control script is `bin/somad`.

![soma_actor message-driven workflow: messages enter the actor, LLM calls produce proposals, policy gates execution, approved work starts runs or actor messages, and the event stream ties the whole result trail together.](docs/diagrams/soma-actor-flow.svg)

## Quick start

Use the packaged `soma` command. It speaks Lisp at the edge and auto-starts the
local daemon on the first client command.

From a release, put `bin/soma` on your `PATH`. From this checkout, build the
local release once and point `SOMA` at the bundled command:

```bash
rebar3 release
SOMA="_build/default/rel/somad/bin/soma"
```

Write a small workflow. This Lisp-flavored workflow language is the public run
format: Lisp at the edge, validated data inside the runtime. Syntax reference:
[docs/lfe-dsl.md](docs/lfe-dsl.md); CLI wire and command behavior:
[docs/cli.md](docs/cli.md).

```bash
mkdir -p /tmp/soma-demo
printf 'hi soma\n' > /tmp/soma-demo/input.txt

cat > /tmp/soma-demo/pipeline.lfe <<'EOF'
(run
  (step read file_read
    (args (path "input.txt") (root "/tmp/soma-demo")))
  (step process echo
    (args (from_step read)))
  (step write file_write
    (args (path "output.txt") (root "/tmp/soma-demo") (bytes (from_step process)))))
EOF

$SOMA run /tmp/soma-demo/pipeline.lfe
cat /tmp/soma-demo/output.txt
```

The result is printed as a Lisp `(result ...)` form carrying a `task-id` and
`correlation-id`. Use those ids to inspect or manage work:

```bash
$SOMA trace "<correlation-id-from-result>"
$SOMA status "<task-id-from-result>"
$SOMA stop
```

Detached tasks outlive the client that started them:

```bash
$SOMA run examples/cli-demo/slow.lfe --detach
$SOMA cancel "<task-id-from-accepted>"
```

`soma ask "..."` drives the actor decision path through the same daemon. It needs
a model configured in `~/.soma/config` and `SOMA_LLM_API_KEY` exported in the
daemon's environment; `soma run` needs no model. See [docs/usage.md](docs/usage.md)
for the user manual, and [docs/cli.md](docs/cli.md) for the full command and Lisp
wire reference.

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
- **An agent entity** (`soma_actor`). A long-lived `gen_statem`
  takes a message envelope through `send/2` (async, returns `{ok, TaskId}`) or
  `ask/3` (blocks the caller for the result), mints `task_id` / `correlation_id`,
  and emits `actor.message.received` / `actor.task.accepted`. If the envelope
  carries `steps`, the actor validates them and starts a `soma_run` it owns; if
  it carries `llm`, the decision path below produces and gates a proposal first.
  On terminal child messages the actor records the result
  (`actor.result.created` / `actor.task.completed`) or failure
  (`actor.task.failed` / `actor.task.cancelled`) and stays alive. Results are
  available three ways: `ask/3` reply, `get_task_status/2` + `get_task_result/2`
  polling, and the event stream — `soma_event_store:by_correlation/2` returns the
  whole task chain (actor, LLM, proposal, and run events) under one
  `correlation_id`.
  `cancel/2` cancels a task's active run for real (the tool worker is killed).
- **Agent decisions.** An envelope can carry an
  `llm` directive instead of `steps`: the actor starts a **supervised, monitored,
  cancellable LLM-call worker** (`soma_llm_call`, owned directly — no
  `soma_llm_call_sup`, mirroring `soma_run → soma_tool_call`), which returns a
  **proposal**. `soma_proposal:normalize/1` validates the proposal into tagged
  data (`reply` / `run_steps` / `reject` / `ask` / `actor_message`); a pure policy
  gate `soma_policy:check/2` allows or rejects it against a tool-name allowlist;
  and only an **approved** `run_steps` proposal starts a `soma_run`. A per-task
  `budget` fails the task (not the actor) on exhaustion, and an approved
  `actor_message` delivers to another actor under the sender's `correlation_id`.
  It emits `llm.*` and `proposal.*` events on the same chain. The test gate still
  drives this layer with the mock LLM, but `soma_llm_call:perform_call/1` now also
  routes `#{provider => openai_compat}` calls to `soma_llm_openai`.
- **A mandatory event log** (in-memory by default) records the whole run, each
  event carrying 8 fields (`event_id, timestamp, session_id, run_id, step_id,
  tool_call_id, event_type, payload`): `session.started -> run.accepted ->
  run.started ->` per step `step.started -> tool.started -> tool.succeeded ->
  step.succeeded -> ... -> run.completed` (or `run.failed` / `run.timeout` /
  `run.cancelled`), and a resumed run emits `run.resumed`. Actor-layer events add `actor.*` types and an
  `actor_id` / `task_id` / `correlation_id` extension; a `soma_run` started by an
  actor stamps the `correlation_id` onto every run event too.
- **A durable event store, opt-in.** The store also has a `disk_log`
  backend: start it with a log path and `append/2` writes each event to the
  durable log *and* the in-memory index, replaying the log on boot to rebuild the
  index — so events survive a BEAM restart. The in-memory store stays the default;
  the prod release turns persistence on by setting one app env
  (`event_store_log`), and the `by_*` query API does not change. The principle is
  **the durable log is the source of truth, the in-memory index is a rebuildable
  cache**.
- **A readable trace view.** `soma_trace:render/2` takes one
  `correlation_id` and renders the whole chain as a timestamp-ordered timeline,
  one line per event (`actor.* -> llm.* -> run.* -> step.* -> tool.* ->
  actor.*`); `soma_trace:timeline/1` is the pure renderer over a list of event
  maps. Read-only, it turns the event stream into an operational view without
  changing it.

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
installed → `_build/prod/rel/somad/somad-0.1.0.tar.gz`. macOS arm64 is built and
verified; the Linux x86_64 / arm64 artifacts build the same `prod` profile on
those hosts and are the remaining packaging work. See
**[docs/release.md](docs/release.md)**.

## Scope

In scope: the runtime, sequential steps, supervised in-BEAM and one-shot CLI
tools, real timeout/cancellation, normalized failures, the event log (in-memory,
with an opt-in durable `disk_log` backend) and a read-only trace view
(`soma_trace`), a compile-only LFE DSL layer (`soma_lfe`), the `soma_actor`
agent-entity skeleton, the agent decision layer (`soma_llm_call` + proposal schema
+ policy gate + decision-loop execution + budgets + actor-to-actor), the
OpenAI-compatible real-provider path, actor-level real-provider planning mode,
the Lisp message/proposal/trace/repair edge forms, manual persistent run resume
(`soma_run_resume_executor:resume/3`), the packaged `bin/soma` Unix-socket task
command, and a self-contained release.

Out of scope (later roadmap layers, see **[docs/roadmap.md](docs/roadmap.md)**): a
productized CLI/config surface for real-model tool planning, an effect-aware
policy gate, MCP, DAG parallelism, distributed Erlang, v0.7.5 auto-resume on
boot, per-tool resume policy / compensation hooks for non-idempotent in-flight
steps, and Linux x86_64 / arm64 release artifacts.

## Docs

**Reference**

- **[docs/design.md](docs/design.md)** — north star: thesis, runtime shape, and
  the non-negotiable constraints. Where the implementation refined the design
  (e.g. step iteration lives inside `soma_run`, not a separate `soma_step`
  process), this README and the code are authoritative.
- **[docs/usage.md](docs/usage.md)** — user manual: getting the `soma` command,
  running workflow files, managing task ids, tracing, cancellation, model
  configuration, durable events, and troubleshooting.
- **[docs/tool-manifest.md](docs/tool-manifest.md)** — tool manifest contract:
  the shape of a tool entry, which adapter runs it, and the cli execution
  protocol.
- **[docs/lfe-dsl.md](docs/lfe-dsl.md)** — LFE DSL: syntax reference,
  run step-list contract, Lisp edge forms, `from_step` forms, diagnostic codes,
  and explicit non-goals. The `soma_lfe` app is a compile-only layer with no
  runtime dependency on `soma_runtime`.
- **[docs/release.md](docs/release.md)** — building and running the release.
- **[docs/roadmap.md](docs/roadmap.md)** — future layers beyond the current
  build and status for the parallel node B / CLI / Lisp tracks.

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
  (P1–P11, P15) are green; P12 and P13 are delivered in v0.5, and P14 remains
  deferred.
- **[docs/contracts/v0.5-test-contract.md](docs/contracts/v0.5-test-contract.md)**
  — process-behaviour proofs for the agent decision layer: the LLM-call worker
  (distinct pid, timeout / cancel / crash become task data, the actor stays
  responsive), proposal normalization, the policy gate, decision-loop execution,
  budget exhaustion, and actor-to-actor `correlation_id` propagation — each
  mapped to its suite and case. Mock-LLM on the gate.
- **[docs/contracts/v0.6-test-contract.md](docs/contracts/v0.6-test-contract.md)**
  — persistence proofs for the durable `disk_log` event store: an appended event
  reads back from the log as its normalized form, a restart at the same path
  replays the log so `all/1` / `by_run/2` / `by_correlation/2` return the events
  in append order, and a truncated tail boots and still serves the intact events
  — while the in-memory default writes no file and queries unchanged.
- **[docs/contracts/L.1-test-contract.md](docs/contracts/L.1-test-contract.md)**
  through **[docs/contracts/L.5-test-contract.md](docs/contracts/L.5-test-contract.md)**
  — Lisp edge-language proofs: message envelopes, actor-to-actor Lisp delivery,
  Lisp proposals, Lisp trace/rendering, and bounded proposal repair.
- **[docs/contracts/cli-1b-test-contract.md](docs/contracts/cli-1b-test-contract.md)**,
  **[docs/contracts/cli-2-test-contract.md](docs/contracts/cli-2-test-contract.md)**,
  and **[docs/contracts/cli-3-test-contract.md](docs/contracts/cli-3-test-contract.md)**
  — local Unix-socket Lisp-wire proofs for `soma_cli` / `soma_cli_server` run,
  ask, status, trace, cancel, and detach behavior.

**Chinese docs**

- **[docs/zh/what-is-soma.zh.md](docs/zh/what-is-soma.zh.md)** — overview of
  Soma, the `soma_actor` agent entity, and the execution path.
- **[docs/zh/soma-actor.zh.md](docs/zh/soma-actor.zh.md)** — soma_actor complete
  design: actor entity, message-driven trigger, actor loop, decision frame,
  policy gate, LLM call, result model, event contract, memory model, and
  minimum scope. The current actor path supports direct step runs, LLM-call
  proposals, policy gating, budgets, actor-to-actor messaging, and an
  OpenAI-compatible endpoint when configured.
- **[docs/zh/erlang-otp-primer.zh.md](docs/zh/erlang-otp-primer.zh.md)** —
  Erlang/OTP primer (BEAM, process, mailbox, gen_server, gen_statem, supervisor,
  port, release) for readers unfamiliar with Erlang.
