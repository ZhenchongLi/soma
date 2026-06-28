---
title: Actors
description: The soma_actor agent entity that owns runs and message-passing.
---

`soma_actor` is the long-lived agent entity. It lives in its own app
(`apps/soma_actor`) above the runtime, with a strict one-way dependency:
`soma_actor` may use `soma_runtime` and `soma_event_store`, but the runtime
never imports the actor.

## A long-lived gen_statem

`soma_actor` is a `gen_statem` running under `soma_actor_sup`
(`simple_one_for_one`). It takes a message envelope through `send/2` or
`ask/3`, mints a `task_id` and a `correlation_id`, and emits `actor.*` events.

```erlang
%% Deliver a message envelope to an actor and wait for its reply.
{ok, Reply} = soma_actor:ask(ActorPid, Envelope, TimeoutMs).
```

## Owning runs directly

On a steps envelope the actor starts a `soma_run` it **owns directly** —
`session_pid => self()`, with no `soma_agent_session` in its path. It starts
the run under `soma_run_sup` and learns the outcome from the
`{run_completed | run_failed | run_timeout | run_cancelled, RunId, ...}`
message that `soma_run` already sends to its `session_pid`.

The actor records the run's result or survives its failure, timeout, or cancel
as data. It exposes a result model — the `ask` reply plus `get_task_status` and
`get_task_result` polling — and `cancel/2`. There is no `soma_llm_call_sup`:
the actor spawns and monitors its workers directly, mirroring how `soma_run`
spawns `soma_tool_call`.

## Full-chain lookup

Every event the actor and its run emit carries the same `correlation_id`, so
`soma_event_store:by_correlation/2` returns the whole chain — the actor
envelope, the decision, the run, and every tool call — for one task.
