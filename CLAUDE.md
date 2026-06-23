# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

This repo is **design-stage**: there is no code yet, only `README.md` (the full v0.1 spec) and `docs/roadmap.md` (post-v0.1 ideas). There is no rebar3 umbrella, no source, and the Erlang toolchain is not installed on this machine. `README.md` is the authoritative spec — read it before implementing anything; the sections below summarize what shapes day-to-day work.

The first implementation task is the "First Commit Checklist" at the end of `README.md`: bootstrap a rebar3 umbrella, add the `soma_runtime` app, and stand up the session/run/tool/event-store skeleton with the v0.1 test contract.

## What Soma is

An Erlang/OTP-native agent runtime. The core thesis: an agent run is **not a function that calls tools in a loop** — it's a supervised OTP process tree. Erlang/OTP provides the execution semantics (timeouts, cancellation, monitoring, crash isolation, restart policy); the step list only says *what* to run.

v0.1 is runtime-only: sequential steps, supervised tool calls, real timeout/cancellation, an in-memory event store, and a Linux x86_64 + arm64 release. Explicitly **out of scope for v0.1**: DAG parallelism, distributed Erlang, complex planning, retries beyond a simple policy, and any hard dependency on a real LLM. Don't pull roadmap items (LFE DSL, MCP, LLM planner, DAG) into v0.1.

## Architecture (the load-bearing parts)

Supervision tree:

```
soma_sup
  ├── soma_event_store
  ├── soma_tool_registry
  ├── soma_session_sup → soma_agent_session   (gen_server, long-lived)
  └── soma_run_sup     → soma_run             (gen_statem, per-run)
                            ├── soma_step       (per-step worker)
                            └── soma_tool_call  (per-tool-call worker, disposable)
```

- **`soma_agent_session`** (`gen_server`, long-lived): owns `session_id` and session metadata, accepts run requests, starts `soma_run` under `soma_run_sup`, tracks active runs, and must **survive failed/timed-out/cancelled runs**. It never executes tool logic directly.
- **`soma_run`** (`gen_statem`, short-lived): owns one execution attempt — step cursor, step results, active tool-call pid, run timeout timer, cancellation, and event emission. Terminal states are explicit: `completed | failed | cancelled | timeout`. It starts each tool call as a monitored worker; **a tool crash is data for the run, not a crash of the session**.
- **`soma_tool_call`** (disposable worker): executes exactly one tool invocation, returns a result/error message to `soma_run`, then dies.

## Non-negotiable constraints

These are the design's whole point — don't violate them for convenience:

- Every tool invocation crosses a **process boundary**. Tool results come back to `soma_run` as messages.
- `soma_run` owns run state; tools never mutate run state directly.
- `soma_agent_session` never executes tools.
- **Cancellation is real**, not a flag checked at the end: cancel → message to `soma_run` → it stops/kills the active tool-call process → records `run.cancelled` → session stays alive.
- Failure isolation is modeled with **processes, links, monitors, and supervision — not a pile of defensive `try/catch`**.
- Events are mandatory from day one (in-memory store is fine for v0.1). Every event carries `event_id, timestamp, session_id, run_id, step_id, tool_call_id, event_type, payload`. See `README.md` for the full event-type list (`session.started` … `run.timeout`).
- External tools use **executable + args, never shell command strings** — no shell interpolation in the core.
- Any external executable in a release is packaged **per target architecture** (x86_64 and arm64 are separate artifacts).

## Tools

A tool is an Erlang behaviour:

```erlang
-callback describe() -> soma_tool:spec().
-callback invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
```

Tool metadata declares `effect` (`identity` | `reader` | `state`), `idempotent`, and `timeout_ms`. v0.1 tools: `echo`, `sleep`, `fail` (errors/crashes, for tests), `file.read`, `file.write` (sandboxed root), and optionally `llm.mock` (deterministic, no network). Real LLM providers wait until runtime behavior is proven.

## Steps (not an IR yet)

v0.1 uses a deliberately small step-list format — a list of maps with `id`, `tool`, `args` (with simple `from_step` references to prior output), and `timeout_ms`. The executor is strictly sequential: validate step → start tool call → wait for result → record event → next step. No branching, loops, DAG, or variables. The runtime must not depend on where steps came from (future planners all compile down to this format).

## The test contract is the priority

Per `README.md`, the v0.1 end-to-end test (demo: `file.read -> echo -> file.write`) matters more than adding integrations. Tests must **assert process survival, not just return values**. The ten required proofs: session starts; run accepted; steps run sequentially; each tool call has its own process; events emitted; a failing tool fails the run; a crashed tool doesn't kill the session; a hanging tool times out; cancelling a run stops the active tool; the session can start another run afterward.

## Intended build commands (once bootstrapped)

The toolchain (`erl`, `rebar3`) is **not yet installed here** — install Erlang/OTP and rebar3 first. The repo is planned as a rebar3 umbrella (`apps/soma_runtime`, `apps/soma_tools`, `apps/soma_event_store`). Standard commands will be:

```bash
rebar3 compile              # build
rebar3 ct                   # run Common Test (end-to-end / process-behavior tests)
rebar3 eunit                # run EUnit (unit tests)
rebar3 ct --suite test/<suite>_SUITE     # run one CT suite
rebar3 eunit --module=<module>           # run one EUnit module
rebar3 shell                # interactive runtime shell
rebar3 dialyzer             # type/discrepancy analysis
rebar3 release              # build a release (target per architecture)
```
