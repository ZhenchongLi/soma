# AGENTS.md

This file provides guidance to Codex when working in this repository.

## Current State

Soma is no longer design-stage. The rebar3 umbrella exists and the runtime is
built on `main`:

- `apps/soma_event_store`: in-memory event store.
- `apps/soma_tools`: tool behaviour, built-in tools, manifests, registry, and
  the one-shot CLI adapter support files.
- `apps/soma_runtime`: session, run, supervision, tool-call worker, timeout,
  cancellation, failure isolation, and event emission.
- `apps/soma_lfe`: compile-only Lisp-flavored DSL layer.

`README.md` is the authoritative high-level spec. Read it before changing
runtime behaviour. The docs under `docs/contracts/` map each behavioural
guarantee to the tests that prove it.

Current README status: EUnit 95 and Common Test 70 green on Erlang/OTP 29. A
self-contained macOS arm64 release is built and verified. Linux x86_64 and
Linux arm64 release artifacts remain the main packaging task.

## What Soma Is

Soma is an Erlang/OTP-native agent runtime. The core thesis:

```text
An agent run is a supervised OTP process tree, not a function that loops over
tool calls.
```

Erlang/OTP provides the execution semantics: process boundaries, mailboxes,
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
```

- `soma_agent_session` owns the session id, accepts run requests, starts
  `soma_run` processes, tracks terminal status, and must survive failed,
  timed-out, and cancelled runs. It never executes tools.
- `soma_run` owns one execution attempt: step cursor, prior step outputs,
  active tool-call pid, active external OS pid for CLI tools, timers,
  cancellation, and event emission. Terminal states are explicit:
  `completed | failed | timeout | cancelled`.
- `soma_tool_call` executes exactly one tool invocation, reports the result or
  error to `soma_run`, then exits. Every tool call crosses this process boundary.

There is no separate `soma_step` worker in the current implementation. Step
iteration lives inside `soma_run` through its `executing` and `waiting_tool`
states.

## Non-Negotiable Constraints

- Every tool invocation crosses a process boundary.
- Tool results return to `soma_run` as messages.
- `soma_run` owns run state; tools never mutate run state directly.
- `soma_agent_session` never executes tools.
- Cancellation is real: cancel the run, stop the active tool-call worker, tear
  down the external CLI OS process when present, emit `run.cancelled`, and keep
  the session alive.
- A tool crash is data for the run, not a session crash.
- Events are mandatory. Each event carries:
  `event_id, timestamp, session_id, run_id, step_id, tool_call_id, event_type,
  payload`.
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
result, record events, continue. No branching, loops, DAG execution, or variables
belong in the runtime step executor.

## LFE DSL

`apps/soma_lfe` is a compile-only Lisp-flavored DSL layer. It parses a small
S-expression grammar into the exact step-list maps accepted by
`soma_agent_session:start_run/2`.

Treat this DSL as Soma's first agent intent language. Its primary user may be
an agent rather than a human, so optimize future language work for generation,
validation, repair, diffing, and audit. Lisp syntax is the surface; the real
design work is choosing the constrained forms and abstractions the runtime can
honestly support.

Important boundary:

```text
DSL source -> soma_lfe:compile/2 -> step list -> soma_agent_session:start_run/2
```

`soma_lfe:compile/2` must remain pure from the runtime's perspective: it starts
no processes, emits no runtime events, and has no dependency on `soma_runtime`.
It is not a general Lisp interpreter and must not execute arbitrary Lisp.

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

v0.2 extends that contract for manifests and CLI tools. v0.3 extends it for the
compile-only LFE DSL boundary. Keep docs and tests aligned:

- `docs/contracts/v0.2-test-contract.md`
- `docs/contracts/v0.3-test-contract.md`

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

`rebar3 eunit && rebar3 ct` is the normal merge gate.

## Scope Discipline

In scope for the current core:

- sequential runs
- supervised tool-call workers
- in-BEAM tools
- one-shot CLI tools
- real timeout and cancellation
- normalized failures
- in-memory event log
- compile-only LFE DSL
- self-contained releases

Out of scope for the current core unless explicitly requested:

- MCP
- real LLM providers
- LLM planner
- DAG parallelism
- distributed Erlang
- persistent run resume

Future layers should compile down to the canonical step-list contract instead of
changing the runtime's execution semantics.
