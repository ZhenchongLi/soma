---
title: Architecture
description: The supervised OTP process tree behind a Soma agent run.
---

The core thesis of Soma is that an agent run is **not a function that calls
tools in a loop** — it is a supervised OTP process tree. Erlang/OTP provides the
execution semantics (timeouts, cancellation, monitoring, crash isolation,
restart policy); the step list only says *what* to run.

The mental model is the actor model plus OTP supervision: every session, run,
and tool call is an actor — an isolated process with a private mailbox,
communicating only by message passing — and OTP's supervision and monitors add
the fault-tolerance layer that is the actual thesis.

## The supervision tree

The runtime lives under `soma_sup`, and the agent-entity layer lives in a
separate app above it with a one-way dependency.

![Supervision tree](/supervision-tree.svg)

```
soma_sup                                        (apps/soma_runtime)
  ├── soma_event_store
  ├── soma_tool_registry
  ├── soma_session_sup → soma_agent_session   (gen_server, long-lived)
  └── soma_run_sup     → soma_run             (gen_statem, per-run)
                            └── soma_tool_call  (per-tool-call worker, disposable)

soma_actor_sup                                  (apps/soma_actor; simple_one_for_one)
  └── soma_actor                              (gen_statem, long-lived agent entity)
```

## The load-bearing processes

- **`soma_agent_session`** (`gen_server`, long-lived) owns `session_id` and
  session metadata, accepts run requests, starts `soma_run` under
  `soma_run_sup`, tracks active runs, and must **survive failed, timed-out, or
  cancelled runs**. It never executes tool logic directly.
- **`soma_run`** (`gen_statem`, short-lived) owns one execution attempt — the
  step cursor, step results, the active tool-call pid, the run timeout timer,
  cancellation, and event emission. Terminal states are explicit:
  `completed | failed | cancelled | timeout`. Steps are iterated inside
  `soma_run` itself; its `executing` / `waiting_tool` states are the step
  cursor, so there is no separate per-step process.

![Run states](/run-states.svg)

- **`soma_tool_call`** (disposable worker) executes exactly one tool
  invocation, returns a result or error message to `soma_run`, then dies. Every
  tool invocation crosses a process boundary.

![Tool call](/tool-call.svg)

## Non-negotiable constraints

These are the design's whole point:

- Every tool invocation crosses a **process boundary**; tool results come back
  to `soma_run` as messages.
- `soma_run` owns run state; tools never mutate run state directly.
- `soma_agent_session` never executes tools.
- **Cancellation is real**, not a flag checked at the end: a cancel message
  reaches `soma_run`, which stops or kills the active tool-call process, records
  `run.cancelled`, and leaves the session alive.
- Failure isolation is modeled with processes, links, monitors, and supervision
  — not a pile of defensive `try/catch`.
