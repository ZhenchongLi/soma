# Soma — design north star

> The thesis, the runtime shape, and the design invariants. For **what is
> actually built and how to run it**, see the [README](../README.md). Where
> the implementation refined the design (e.g. step iteration lives inside
> `soma_run` rather than a separate `soma_step` process, and a `cli` tool's
> port is owned by `soma_tool_call`), the README and the code are authoritative.

Soma is an Erlang/OTP-native agent runtime.

The core idea:

```text
An agent run is a supervised OTP process tree, not a function that loops over
tool calls.
```

The execution core — sessions, runs, tool calls — is built and proven
(v0.1–v0.3). The next layer is `soma_actor`: a long-lived, LLM-capable agent
entity that uses that execution core to carry out intentions.

## Thesis

Agent systems fail in operational ways:

- model calls hang;
- tools time out;
- external programs crash;
- user sessions stay alive for a long time;
- partial writes need guardrails;
- cancellation must be real;
- every run needs an audit trail;
- failures must not poison the whole session.

Erlang/OTP is unusually well suited to these problems. Soma uses the parts of
Erlang that are hard to reproduce cleanly elsewhere:

- lightweight processes;
- isolated mailboxes;
- supervision trees;
- `gen_server` for long-lived actors;
- `gen_statem` for run state machines;
- links and monitors;
- timers and cancellation messages;
- ports for external tool processes;
- crash isolation as a design primitive.

## Core Principle

Soma is built on the **actor model** at every layer. A session, a run, a tool
call, and an agent entity are all *actors* — isolated processes with private
mailboxes that communicate only by message-passing. OTP supervision trees and
monitors add the fault-tolerance layer the thesis depends on.

Do not implement an agent run as a normal function.
Do not implement an agent entity as a function loop that calls an LLM.
Implement both as OTP process trees.

Full architecture:

```text
soma_actor_sup
  └── soma_actor              long-lived gen_statem; agent entity

soma_llm_call_sup
  └── soma_llm_call           disposable worker; one model call

soma_run_sup
  └── soma_run                gen_statem; one execution attempt
        └── soma_tool_call    disposable worker; one tool invocation
```

The execution core (v0.1–v0.3) proves the bottom two layers. `soma_actor` is
the next layer above them.

## Scope

**Built (v0.1–v0.3):** the execution core.

- session process (`soma_agent_session`);
- run process (`soma_run`, `gen_statem`);
- sequential steps;
- supervised tool calls, each behind a process boundary;
- timeout and cancellation, including teardown of a cli tool's external OS process;
- a tool registry over normalized manifests;
- in-BEAM tools and a one-shot CLI/port adapter;
- normalized cli failures (bounded, named errors);
- event emission and in-memory event store;
- a compile-only LFE DSL layer (`soma_lfe`);
- end-to-end tests around process behavior;
- a self-contained release.

**Next (v0.4):** `soma_actor` — the agent entity layer.

**Later:** LLM planner, DAG parallelism, distributed Erlang, persistent
resume. See [roadmap.md](roadmap.md).

## Done Means

A layer is done when the runtime can execute a sequential run and prove its
failure semantics under test — process survival, not just return values.

Required demo for the execution core:

```text
file_read -> echo -> file_write
```

Required guarantees (proven for both in-BEAM and cli tools):

- a tool crash does not kill the session;
- a hanging tool is stopped by timeout — for a cli tool the external OS process is killed too;
- cancelling a run stops the active tool, and its external process;
- a cli tool's operational failures (missing/unrunnable executable, nonzero exit,
  oversized output) become bounded `{error, _}` data, not a session crash;
- the event log explains the run from start to terminal state;
- a session can start another run after failure, timeout, or cancellation.

Release targets (one artifact per architecture):

```text
macOS arm64   (built and verified)
Linux x86_64  (remaining)
Linux arm64   (remaining)
```

## Runtime Shape

Supervision tree, as built:

![Soma supervision tree, as built](diagrams/supervision-tree.svg)

The session process is long-lived. It owns session metadata and starts runs.

The run process is short-lived. It owns one execution attempt as a `gen_statem`.
Its states are `executing` / `waiting_tool` (the step cursor) and the four
explicit terminal states: `completed | failed | timeout | cancelled`.

The tool call process is disposable. It executes one tool invocation and exits
after returning a result or error. For a `cli` tool it also holds the external
OS process pid and tears it down on exit.

`soma_actor` sits above this tree as its own supervised entity. The execution
core stays unchanged; `soma_actor` uses `soma_run` as its execution path.

## Agent Session

`soma_agent_session` is a `gen_server`. It owns `session_id`, accepts run
requests, starts `soma_run` under `soma_run_sup`, tracks active runs, and
survives any run's failure. It does not execute tool logic.

`soma_actor` adds the agent entity concept above this: `soma_actor` owns its
own identity, mailbox, and state, and starts runs directly.

## Agent Run

`soma_run` is a `gen_statem`. It owns one execution attempt.

States:

```text
accepted
  -> executing / waiting_tool   (step cursor loop)
  -> completed | failed | cancelled | timeout
```

![soma_run state machine](diagrams/run-states.svg)

Owned by the run:

- step cursor;
- step results;
- active tool call pid;
- active cli OS pid (for teardown on timeout/cancel);
- run timeout timer;
- cancellation handling;
- event emission.

The run monitors each tool call worker. A tool crash arrives as a monitor
`'DOWN'` — it fails the step, not the session.

## Agent Entity: soma_actor

`soma_actor` is the agent entity layer. It is a long-lived OTP process with LLM
capability that uses `soma_run` to execute intentions.

Non-negotiable invariants:

- Work enters `soma_actor` as a **message** — an envelope carrying `task_id`
  and `correlation_id`. External APIs are envelope wrappers; they do not bypass
  the actor mailbox.
- **`soma_actor` owns execution.** LLM calls and rules produce *proposals*;
  the actor validates them through a policy gate before acting. LLM output is
  never executed directly.
- Every significant child operation (LLM call, run, actor message) is a
  **supervised worker**. Results come back as messages; `soma_actor` never
  blocks on a child.
- `soma_actor` must survive any child failure: a crashed LLM call, a failed
  run, a cancelled task — none of these crash the actor.
- Results are available three ways: `ask/reply` for short tasks; `task_id` +
  event stream for long tasks; polling for simple integrations.
- The **event stream is the source of truth**. Reply and polling are
  convenience interfaces over it.

Actor loop:

```text
incoming message / event
  -> update actor / task state
  -> load memory / context
  -> build decision frame
  -> decide next action (rules or LLM)
  -> validate proposal through policy gate
  -> execute action
  -> receive result as message
  -> next loop or terminal result
```

`soma_actor` is a state machine that treats LLM output as input to a policy
gate, not a while loop that executes LLM output directly.

`correlation_id` must propagate across all child operations (LLM call, run,
actor-to-actor message) so the full task chain is traceable in the event log.

The minimal `soma_actor` slice — fixed-rule decisions, no real LLM — is enough
to prove the actor loop and its integration with `soma_run`. The LLM planner
and full policy gate layer on top once the skeleton is green under test.

The full specification — actor loop, decision frame, policy gate, LLM call,
result model, event contract, memory model, budget and backpressure,
actor-to-actor messaging, test contract — is in
[zh/soma-actor.zh.md](zh/soma-actor.zh.md).

## Planning Layer

The runtime does not depend on where steps came from. Any planning input —
hand-authored, LFE DSL, LLM output, workflow UI — compiles down to the step
format `start_run/2` accepts.

The intended primary author of higher-level plans is an agent, not necessarily
a human. That shifts the language design goal: the DSL should be easy for an
agent to generate, validate, repair, diff, and audit. Lisp syntax is useful
because it is a small tree-shaped surface, but the important design work is the
set of forms and abstractions Soma exposes.

Soma's DSL is therefore an **agent intent language**, not a general-purpose
Lisp runtime. Its job is to express bounded operational intent:

- what run is being proposed;
- which steps exist and in what order;
- which tool each step requests;
- what arguments and prior outputs flow into each step;
- what execution constraints apply, such as timeouts;
- later, what capabilities, effects, budgets, and policies bound the run.

This is similar in spirit to a solver exposing constrained extension points:
the extension language is valuable because it names safe hooks into a much
larger execution engine, not because it can do arbitrary computation. In Soma,
the execution engine is OTP. The DSL proposes; compiler and policy validate;
`soma_run` executes through supervised processes.

The LFE DSL (`soma_lfe`) is the first planning input: a compile-only layer in
its own OTP application. The dependency is one-way: `soma_lfe` depends on
shared data contracts, but `soma_runtime` has no dependency on `soma_lfe`.

```erlang
soma_lfe:compile(Source :: binary(), Opts :: map()) ->
    {ok, #{run => #{steps => [map()]}}} | {error, [map()]}.
```

`compile/2` is pure: no processes started, no events emitted, no supervisor
tree touched. Failure returns `{error, Diagnostics}` with stable diagnostic
codes and never partially compiles.

Full syntax reference: [lfe-dsl.md](lfe-dsl.md).

## Steps

The step-list format and sequential executor are documented in the [README](../README.md).

## Tool Runtime

The tool behaviour, manifest contract, and adapter specs are in [tool-manifest.md](tool-manifest.md).

## External Processes

The cli adapter execution protocol — executable + argv, OS pid teardown, failure modes — is in [tool-manifest.md](tool-manifest.md).

## Event Log

Events are mandatory. The event stream is the audit trail for the full run.

Execution-core events:

```text
session.started
run.accepted
run.started
step.started
tool.started
tool.succeeded / tool.failed
step.succeeded / step.failed
run.completed / run.failed / run.cancelled / run.timeout
```

Actor-layer events (soma_actor):

```text
actor.started
actor.message.received
actor.task.accepted
actor.proposal.created
actor.policy.allowed / actor.policy.rejected
actor.result.created
actor.task.completed / actor.task.failed / actor.task.cancelled
llm.started
llm.succeeded / llm.failed
```

Every event carries `event_id`, `timestamp`, `session_id`, `run_id`,
`step_id`, `tool_call_id`, `event_type`, `payload`. Actor-layer events extend
this schema with `actor_id`, `task_id`, `correlation_id`, and `llm_call_id`.

## Cancellation and Timeout

Cancellation is a runtime feature, not a flag checked at the end.

**Run level:** cancelling a run sends a message to `soma_run`; `soma_run` kills
the active tool call worker; for a `cli` tool the external OS process is killed
too; the run records `run.cancelled`; the session stays alive.

**Actor level:** cancelling a task sends a message to `soma_actor`; `soma_actor`
cancels the active run and any active LLM call; the actor records
`actor.task.cancelled`; the actor stays alive and accepts the next message.

Timeout mirrors cancellation at each layer.

## Failure Semantics

Failure must be boring. Each layer has its own failure type; they must not
collapse into each other.

```text
llm_call failed    inference failure; soma_actor receives a message
tool_call failed   tool error or crash; soma_run receives a monitor 'DOWN'
run failed         terminal state; soma_agent_session / soma_actor receives a message
task failed        actor-layer failure; soma_actor records it, stays alive
actor crashed      supervisor handles restart policy
```

A tool crash is not a task failure. A run failure is not an actor crash. These
are modeled as process and message behavior, not as defensive `try/catch`.

## Implementation Constraints

Non-negotiable for the execution core:

- Every tool invocation crosses a **process boundary**. Tool results come back
  to `soma_run` as messages.
- `soma_run` owns run state; tools never mutate run state directly.
- `soma_agent_session` never executes tools.
- Cancellation is real: cancel → message → kill worker → record event →
  session / actor stays alive.
- Failure isolation uses **processes, links, monitors, supervision** — not
  defensive `try/catch`.
- External tools use **executable + argv, never shell command strings**.
- Events are mandatory.

For `soma_actor`:

- Work enters through the **mailbox** — no bypassing the actor.
- **LLM/rules produce proposals**; `soma_actor` owns the policy gate and
  execution.
- `soma_actor` never blocks on a child operation; every child result is a
  message.
- `soma_actor` survives every child failure.
- `correlation_id` propagates across all child operations.

## Test Contract

Every layer proves its process behavior under test before the next layer is
added. Tests assert **process survival**, not only return values.

**Execution core (v0.1–v0.3):**

1. a session starts;
2. a run is accepted;
3. steps execute sequentially;
4. each tool call has its own process boundary;
5. events are emitted;
6. a failing tool fails the run;
7. a crashed tool does not kill the session;
8. a hanging tool times out;
9. cancelling a run stops the active tool;
10. the session can start another run afterward.

Proof-to-test maps: [contracts/v0.2-test-contract.md](contracts/v0.2-test-contract.md)
and [contracts/v0.3-test-contract.md](contracts/v0.3-test-contract.md).

**Agent entity (soma_actor):**

1. actor starts and emits `actor.started`;
2. actor receives a message and creates `task_id` / `correlation_id`;
3. actor runs fixed steps through `soma_run`;
4. run completion produces an actor result;
5. `ask` receives a final reply;
6. long tasks are queryable by `task_id`;
7. events are queryable by `correlation_id`;
8. actor survives a run failure;
9. actor survives a tool crash;
10. cancel task cancels the active run;
11. actor accepts another message after failure, cancel, or timeout;
12. actor-to-actor message preserves `correlation_id`;
13. budget exhaustion fails the task, not the actor;
14. policy rejection fails or asks, not the actor;
15. actor stays responsive while a child LLM call or run is active.

## Design Principles

- Agents are actors.
- Runs are state machines.
- Tool calls are isolated processes.
- LLM/rules produce proposals; actors own execution.
- Events explain everything.
- Cancellation must be real.
- Each layer earns the next by proving its failure semantics under test.
- Erlang's supervision model is the product advantage.
