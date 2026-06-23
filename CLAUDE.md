# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

The **v0.1 runtime is built and merged**: the rebar3 umbrella (`apps/soma_runtime`, `apps/soma_tools`, `apps/soma_event_store`) is in place, the Erlang toolchain (Erlang/OTP 29, rebar3 3.27) is installed, and all ten proofs of the v0.1 test contract pass (EUnit 21, CT 28, all green on `main`). `README.md` remains the authoritative spec — read it before extending anything; the sections below summarize what shapes day-to-day work.

Done so far: the in-memory event store; the tool behaviour + registry + the five v0.1 tools; the session/run/tool-call execution core (sequential steps, `from_step` wiring, the `file_read → echo → file_write` demo); and the full failure semantics (error, crash isolation, timeout, cancellation). What remains for the *full* README "v0.1 Done Means": the Linux x86_64 + arm64 release packaging (build/CI work, not runtime logic).

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
                            └── soma_tool_call  (per-tool-call worker, disposable)
```

- **`soma_agent_session`** (`gen_server`, long-lived): owns `session_id` and session metadata, accepts run requests, starts `soma_run` under `soma_run_sup`, tracks active runs, and must **survive failed/timed-out/cancelled runs**. It never executes tool logic directly.
- **`soma_run`** (`gen_statem`, short-lived): owns one execution attempt — step cursor, step results, active tool-call pid, run timeout timer, cancellation, and event emission. Terminal states are explicit: `completed | failed | cancelled | timeout`. It starts each tool call as a monitored worker; **a tool crash is data for the run, not a crash of the session**. Steps are iterated inside `soma_run` itself — its `executing` / `waiting_tool` states are the step cursor, so there is no separate per-step process (the design's `soma_step` was folded into the state machine); `soma_tool_call` is the only worker it spawns. The per-step timeout is a `state_timeout`; a crashing tool arrives as the worker monitor's `'DOWN'`.
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

Tool metadata declares `effect` (`identity` | `reader` | `state`), `idempotent`, and `timeout_ms`. v0.1 tools (built): `echo`, `sleep`, `fail` (errors/crashes, for tests), and `file_read` / `file_write` (sandboxed root, sharing `soma_tool_file` for path resolution). They register under those atom names — the README's `file.read` / `file.write` map to `file_read` / `file_write`. `llm.mock` was left out of v0.1; real LLM providers wait until runtime behavior is proven.

## Steps (not an IR yet)

v0.1 uses a deliberately small step-list format — a list of maps with `id`, `tool`, `args` (with simple `from_step` references to prior output), and `timeout_ms`. The executor is strictly sequential: validate step → start tool call → wait for result → record event → next step. No branching, loops, DAG, or variables. The runtime must not depend on where steps came from (future planners all compile down to this format).

## The test contract is the priority

Per `README.md`, the v0.1 end-to-end test (demo: `file_read -> echo -> file_write`) matters more than adding integrations. Tests must **assert process survival, not just return values**. The ten required proofs: session starts; run accepted; steps run sequentially; each tool call has its own process; events emitted; a failing tool fails the run; a crashed tool doesn't kill the session; a hanging tool times out; cancelling a run stops the active tool; the session can start another run afterward.

All ten are implemented and green: the happy-path proofs live in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl` and the failure-mode proofs in `soma_run_failure_SUITE.erl`. Hold this bar (real process-survival assertions) for any extension.

## Build commands

The toolchain is installed (Erlang/OTP 29, rebar3 3.27) and the rebar3 umbrella is in place (`apps/soma_runtime`, `apps/soma_tools`, `apps/soma_event_store`). The relay merge gate runs `rebar3 eunit && rebar3 ct`. Commands:

```bash
rebar3 compile              # build
rebar3 ct                   # run Common Test (end-to-end / process-behavior tests)
rebar3 eunit                # run EUnit (unit tests)
rebar3 ct --suite apps/<app>/test/<suite>_SUITE   # run one CT suite
rebar3 eunit --module=<module>                    # run one EUnit module
rebar3 shell                # interactive runtime shell
rebar3 dialyzer             # type/discrepancy analysis
rebar3 release              # build a release (target per architecture)
```
