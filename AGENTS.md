# AGENTS.md

This file provides guidance to Codex when working in this repository.

## Current State

Soma is no longer design-stage. The rebar3 umbrella exists and the core layers
are built. `README.md` remains the authoritative high-level spec; read it before
changing runtime behaviour. The docs under `docs/contracts/` map behavioural
guarantees to the tests that prove them.

Current local gate observed in this checkout: EUnit 342 and Common Test 354
green on Erlang/OTP 29. A self-contained macOS arm64 release is built and
verified. Linux x86_64 and Linux arm64 release artifacts remain packaging/CI
work, not runtime logic.

Built apps:

- `apps/soma_event_store`: in-memory event store, opt-in `disk_log`
  persistence, trace rendering, and term-to-Lisp rendering.
- `apps/soma_tools`: tool behaviour, built-in tools, manifests, registry, and
  one-shot CLI adapter support files.
- `apps/soma_runtime`: session, run, supervision, tool-call worker, timeout,
  cancellation, failure isolation, event emission, LLM-call worker, and
  OpenAI-compatible provider support.
- `apps/soma_actor`: actor entity, proposal/policy/budget logic,
  actor-to-actor messages, real-provider actor wiring, and local CLI
  server/client modules.
- `apps/soma_lfe`: compile-only Lisp-flavored DSL and edge-form parser.

Layer status:

- v0.1 runtime core is built: event store, tool behaviour/registry, built-in
  tools, session/run/tool-call execution, sequential steps, `from_step` wiring,
  and failure semantics.
- v0.2 tool manifests and CLI/port adapter are built: normalized manifests,
  descriptor registry, shell-free port execution, timeout/cancel teardown of
  external OS processes, and normalized CLI failures.
- v0.3 LFE DSL is built: `soma_lfe:compile/2` parses constrained Lisp-flavored
  source into the exact step-list maps accepted by the runtime. Compile-only:
  no processes, no runtime events, no dependency on `soma_runtime`.
- v0.4 `soma_actor` is built: long-lived `gen_statem` actor, `send/2` and
  `ask/3`, task/correlation ids, actor events, direct owned `soma_run` starts,
  polling, cancellation, and correlation lookup.
- v0.5 decision layer is built: `soma_llm_call`, proposal normalization,
  name-based policy gate, approved proposal execution, budgets, and
  actor-to-actor messages. This layer was mock-LLM only when built; real
  providers are added by node B.
- v0.6 durability and observability are built: `soma_trace`, durable
  `disk_log` event store, and app-env wiring through `soma_runtime`
  `event_store_log`.
- v0.7 persistent resume is built through boot auto-resume: `run.started`
  journals steps and durable options, `soma_run_resume:reconstruct/2` rebuilds
  progress from the durable trail, `soma_run_resume_plan:plan/2` classifies the
  restart decision, and `soma_run_resume_executor:resume/3` starts a resumed run
  or fails clearly on a non-idempotent in-flight state step. The durable event
  store reports interrupted runs and `soma_runtime` boot hands them to the same
  executor.
- node B real-provider path is built: `soma_llm_openai` handles an
  OpenAI-compatible chat API behind `soma_llm_call:perform_call/1`; actor
  `model_config` can route to it. Gate tests use fixed response seams and do not
  open network sockets. Live smoke is opt-in via `soma_llm_smoke:run/0` and
  `SOMA_LLM_API_KEY`.
- Lisp edge language L.1-L.5 is built: the bounded Soma Lisp v1 public task surface
  with `(task ...)` task sources, `(msg ...)` envelopes, actor-to-actor
  Lisp bodies, Lisp proposals, Lisp audit/trace rendering, and bounded
  self-repair that re-enters the normal normalize/policy/budget path.
- Local CLI/daemon product surface is built: `soma_cli_server`, `soma_cli`,
  `soma_cli_task_registry`, `soma_cli_main`, and the overlaid `scripts/soma`
  wrapper support `soma run` / `ask` / `status` / `trace` / `cancel` / `stop` /
  `daemon` over a local Unix socket, with Lisp on the wire, detach, cancellation
  on disconnect, daemon auto-start, and the release's node-control script renamed
  to `bin/somad`.

Latest runtime layer: **v0.7 persistent resume** is in through v0.7.5 (#198).
The resume layer now includes event-store interrupted-run discovery and
auto-resume on boot. Other open tracks: structured real-model planning that
emits tool-running proposals, effect-aware policy, log/index compaction, and
Linux release artifacts.

## What Soma Is

Soma is an Erlang/OTP-native agent runtime. The core thesis:

```text
An agent run is a supervised OTP process tree, not a function that loops over
tool calls.
```

Erlang/OTP provides execution semantics: process boundaries, mailboxes,
monitors, timers, cancellation, crash isolation, and supervision. The step list
only says what to run.

Do not collapse a run back into an in-process tool loop. Do not replace process
isolation with broad defensive `try/catch`.

## Architecture

Runtime supervision shape:

```text
soma_sup
  |-- soma_event_store
  |-- soma_tool_registry
  |-- soma_session_sup -> soma_agent_session  (gen_server, long-lived)
  `-- soma_run_sup     -> soma_run            (gen_statem, per-run)
                              `-- soma_tool_call (per-tool-call worker)

soma_actor_sup                              (apps/soma_actor)
  `-- soma_actor                            (gen_statem, long-lived actor)
```

- `soma_agent_session` owns the session id, accepts run requests, starts
  `soma_run` processes, tracks terminal status, and must survive failed,
  timed-out, and cancelled runs. It never executes tools.
- `soma_run` owns one execution attempt: step cursor, prior step outputs,
  active tool-call pid, active external OS pid for CLI tools, timers,
  cancellation, and event emission. Terminal states are explicit:
  `completed | failed | timeout | cancelled`.
- `soma_tool_call` executes exactly one tool invocation, reports the result or
  error to `soma_run`, then exits. Every tool call crosses this process
  boundary.
- `soma_actor` sits above the runtime as a separate app. It owns tasks and starts
  runs directly under `soma_run_sup` with `session_pid => self()`. The runtime
  must not import `soma_actor`.
- `soma_llm_call` is a disposable worker owned directly by `soma_actor`; there
  is no `soma_llm_call_sup`.

There is no separate `soma_step` worker in the current implementation. Step
iteration lives inside `soma_run` through its `executing` and `waiting_tool`
states.

## Non-Negotiable Constraints

- Every tool invocation crosses a process boundary.
- Tool results return to `soma_run` as messages.
- `soma_run` owns run state; tools never mutate run state directly.
- `soma_agent_session` never executes tools.
- `soma_actor` never executes tool logic directly; it starts/observes runs and
  LLM-call workers.
- Cancellation is real: cancel the run, stop the active tool-call worker, tear
  down the external CLI OS process when present, emit `run.cancelled`, and keep
  the session/actor alive.
- A tool crash is data for the run, not a session crash.
- LLM-call timeout, crash, cancellation, rejection, and budget exhaustion are
  task data, not actor crashes.
- Events are mandatory. Core run events carry:
  `event_id, timestamp, session_id, run_id, step_id, tool_call_id, event_type,
  payload`. Actor/LLM/proposal events extend that trail with ids such as
  `actor_id`, `task_id`, and `correlation_id`.
- API keys and provider secrets must never be emitted into events or committed.
- External tools use executable plus argv, never shell command strings.
- External executable release artifacts are per target architecture.

## Tools

A tool is an Erlang behaviour:

```erlang
-callback describe() -> soma_tool:spec().
-callback invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
```

Built-in in-BEAM tools use the `erlang_module` adapter:

- `echo`
- `sleep`
- `fail`
- `file_read`
- `file_write`

Tool manifests are normalized by `soma_tool_manifest:normalize/1`. The registry
stores descriptors, not bare modules. `soma_tool_registry:resolve_descriptor/1`
is the normal runtime path.

The `cli` adapter launches an external executable through an Erlang port using
`open_port({spawn_executable, ...})`. Input is passed as the final argv argument,
stdout is captured as output, exit status 0 is success, and operational failures
are normalized into bounded `{error, _}` data. The core must not use shell
interpolation.

## Steps

The runtime accepts a small sequential step-list format:

```erlang
#{id => StepId, tool => ToolName, args => Args, timeout_ms => TimeoutMs}
```

`timeout_ms` is optional. `args` may include:

- `#{from_step => StepId}` to pass a prior step's whole output.
- `#{key => {from_step, StepId}}` to pass a prior step's output into one field.

The executor is strictly sequential: validate step, start tool call, wait for
result, record events, continue. No branching, loops, DAG execution, or
variables belong in the runtime step executor.

Future planners, Lisp edge forms, and CLI workflows must compile down to this
canonical step-list contract instead of changing `soma_run` into a general
workflow engine.

## LFE And Lisp Edge Forms

`apps/soma_lfe` is a compile-only Lisp-flavored DSL layer. It parses constrained
S-expression grammar into existing Erlang maps:

- `(run ...)` -> step-list run map.
- `(msg ...)` -> actor envelope map.
- `(reply ...)`, `(run-steps ...)`, `(reject ...)`, `(ask ...)`,
  `(actor-message ...)` -> proposal maps.
- `(ask ...)`, `(trace ...)`, `(status ...)`, `(cancel ...)` -> CLI command
  maps.

Important boundary:

```text
DSL/source form -> soma_lfe:compile/2 -> existing maps -> runtime/actor APIs
```

`soma_lfe:compile/2` must remain pure from the runtime's perspective: it starts
no processes, emits no runtime events, and has no dependency on `soma_runtime`.
It is not a general Lisp interpreter and must not execute arbitrary Lisp.

Lisp is accepted at system edges and rendered for audit/trace; Erlang/OTP remains
the internal execution substrate.

## LLM And Proposals

`soma_llm_call` is a per-call worker. Mock calls stay the hermetic test default.
Real calls are opt-in through `#{provider => openai_compat, ...}` and route to
`soma_llm_openai`.

`soma_proposal:normalize/1` is the validate/normalize boundary. Proposals are
data, not execution. `soma_policy:check/2` currently gates by tool name
allowlist. Approved `run_steps` proposals start an owned `soma_run`; toolless
proposals complete with proposal data; `actor_message` proposals deliver to a
target actor under the sender's `correlation_id`.

Malformed Lisp proposals may enter the bounded repair path. A repaired proposal
must re-enter the full normalize, policy, and budget path. Repair is never a
bypass.

## CLI / Daemon

The local task daemon path is implemented as Erlang modules:

- `soma_cli_server`: local Unix-socket listener and request handler.
- `soma_cli`: thin client functions for run/ask/status/trace/cancel.
- `soma_cli_task_registry`: live detached task registry.

The wire is Lisp S-expressions, not JSON. The server parses request forms with
`soma_lfe` and renders replies with `soma_lisp`. Synchronous run/ask cancellation
on disconnect is real; detached runs outlive the client and can be queried or
cancelled by task id.

Do not confuse the task command with the release control script. The release is
named `somad`, so `bin/somad` is the OTP node-control script (`console`,
`foreground`, `daemon`, `stop`, etc.). The user-facing task command is the
overlaid `bin/soma` wrapper, which dispatches `run` / `ask` / `status` /
`cancel` / `trace` / `stop` / `daemon` to `soma_cli_main` over the local socket.

## Tests Are The Contract

Tests must assert process behaviour, not just return values. The baseline proofs
include:

- session starts
- run accepted
- steps run sequentially
- each tool call has its own process
- events emitted
- failing tool fails the run
- crashed tool does not kill the session
- hanging tool times out
- cancelling a run stops the active tool
- session can start another run afterward

Keep docs and tests aligned:

- `docs/contracts/v0.2-test-contract.md`
- `docs/contracts/v0.3-test-contract.md`
- `docs/contracts/v0.4-test-contract.md`
- `docs/contracts/v0.5-test-contract.md`
- `docs/contracts/v0.6-test-contract.md`
- `docs/contracts/L.1-test-contract.md` through
  `docs/contracts/L.5-test-contract.md`
- `docs/contracts/cli-test-contract.md`
- `docs/contracts/cli-1b-test-contract.md`
- `docs/contracts/cli-2-test-contract.md`
- `docs/contracts/cli-3-test-contract.md`

The normal merge gate is `rebar3 eunit && rebar3 ct`. `rebar3 dialyzer` is useful
but is not the current gate; baseline warnings have been documented separately
in the CLI contract material.

## Build Commands

Use the repository's rebar3 umbrella:

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 eunit --module=<module>
rebar3 ct --suite apps/<app>/test/<suite>_SUITE
rebar3 dialyzer
rebar3 shell
rebar3 as prod tar
```

## Development Workflow

Use relay with the Codex source for substantive development in this repository.
The normal path is:

```bash
relay run --project soma --issue <issue-number> --source codex
```

For new implementation work, first create or refine a GitHub `[cc]` issue with
testable acceptance criteria, get approval, then let relay drive the
requirements / architect / dev / review / PR flow. Keep manual edits limited to
small repository hygiene, read-only investigation, or explicitly requested
emergency fixes; do not hand-drive runtime, CLI, actor, Lisp, resume, or
packaging slices when they can go through relay.

## Scope Discipline

In scope for the current core:

- sequential runs
- supervised tool-call workers
- in-BEAM tools
- one-shot CLI tools
- real timeout and cancellation
- normalized failures
- in-memory event log
- opt-in durable event log
- trace rendering
- compile-only LFE DSL
- `soma_actor` message/task layer
- mock-gated LLM decision layer
- OpenAI-compatible provider path
- Lisp message/proposal/trace/repair edge forms
- manual persistent run resume
- boot auto-resume
- packaged local Unix-socket `soma` task command
- self-contained releases

Out of scope for the current core unless explicitly requested:

- MCP
- structured real-model planner that emits tool-running proposals
- effect-aware policy gate
- human-in-the-loop policy ask path
- DAG parallelism
- distributed Erlang
- per-tool resume policy or compensation hooks
- log rotation, compaction, or bounded task/event indexes
- Linux x86_64 / Linux arm64 release artifacts

Future layers should compile down to the canonical step-list contract instead of
changing the runtime's execution semantics.
