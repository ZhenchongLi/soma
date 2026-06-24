# Roadmap

v0.1 (runtime core), v0.2 (tool manifests + CLI/port adapter), and v0.3 (LFE
DSL compile-only layer) are built and merged. The sequence below is what comes
next.

## Sequence

```text
v0.1  Erlang/OTP agent runtime                       [done]
v0.2  tool manifests and CLI/port adapter            [done]
v0.3  LFE DSL → steps                               [done]
v0.4  soma_actor — agent entity skeleton
v0.5  soma_actor + LLM planner
v0.6  MCP client adapter
v0.7  DAG execution
v0.8  persistent resume
```

## v0.4 — soma_actor skeleton

`soma_actor` is the agent entity: a long-lived OTP process that receives
messages, creates tasks, starts runs, and returns results. The minimum slice
uses fixed-rule decisions and no real LLM — enough to prove the actor loop and
its integration with `soma_run`.

Minimum capabilities:

- start `soma_actor` with `actor_id`, `model_config`, `tool_policy`;
- receive an envelope through `send/ask`, create `task_id` / `correlation_id`;
- emit `actor.message.received` / `actor.task.accepted`;
- fixed-rule decision: envelope has steps → validate and start `soma_run`;
- observe run terminal result; emit `actor.result.created` / `actor.task.completed`;
- `ask/reply` for short tasks; `get_task_status` / `get_task_result` for polling;
- event lookup by `correlation_id`;
- cancel task → cancel active run.

Not in v0.4: real LLM planner, MCP, DAG, persistent resume, complex memory
backend.

Design specification:
[zh/soma-actor-final-design.zh.md](zh/soma-actor-final-design.zh.md).

## v0.5 — soma_actor + LLM planner

Add `soma_llm_call` as a supervised disposable worker. Add a structured
proposal schema and a policy gate over LLM output. A decision that rules
cannot resolve calls `soma_llm_call`; the result is a proposal that
`soma_actor` validates through the policy gate before executing.

## v0.6 — MCP client adapter

Connect external tools through the Model Context Protocol. MCP becomes a new
tool adapter type alongside `erlang_module` and `cli`; the runtime executes
MCP-backed steps through the same process boundary, timeout, and cancel
semantics as built-in tools.

## v0.7 — DAG execution

Extend the step executor to fan out and join parallel branches. The step
format grows a dependency graph; `soma_run` spawns parallel tool call workers
and waits for branches to complete before advancing.

## v0.8 — persistent resume

Add a persistent event store and a run journal that survives BEAM restarts. A
resumed run replays the event trail to the last committed step and continues
from there.

## Rule

Do not add a layer until the layer below it has test coverage for its failure
semantics.
