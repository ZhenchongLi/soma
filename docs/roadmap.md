# Roadmap

v0.1 (runtime core), v0.2 (tool manifests + CLI/port adapter), v0.3 (LFE DSL
compile-only layer), and v0.4 (the `soma_actor` agent-entity skeleton) are built
and merged. The sequence below is what comes next.

The important sequencing rule is unchanged: do not add a layer until the layer
below it has test coverage for its failure semantics. The next work is therefore
not "make the agent smarter" first; it is to close the actor contract, then add
LLM planning as another supervised child operation.

## Sequence

```text
v0.1    Erlang/OTP agent runtime                       [done]
v0.2    tool manifests and CLI/port adapter            [done]
v0.3    LFE DSL -> steps                               [done]
v0.4    soma_actor -- agent entity skeleton            [done]
v0.4.1  actor hardening + release/docs alignment       [done]
v0.5    LLM worker + proposal + policy + budget
v0.6    trace tooling + persistent event store
v0.7    persistent resume
v0.8    DAG / parallel execution, only if still needed
```

## v0.4 — soma_actor skeleton [done]

`soma_actor` is the agent entity: a long-lived OTP process that receives
messages, creates tasks, starts runs, and returns results. The minimum slice
uses fixed-rule decisions and no real LLM -- enough to prove the actor loop and
its integration with `soma_run`.

Minimum capabilities:

- start `soma_actor` with `actor_id`, `model_config`, `tool_policy`;
- receive an envelope through `send/ask`, create `task_id` / `correlation_id`;
- emit `actor.message.received` / `actor.task.accepted`;
- fixed-rule decision: envelope has steps -> start `soma_run`;
- observe run terminal result; emit `actor.result.created` / `actor.task.completed`;
- `ask/reply` for short tasks; `get_task_status` / `get_task_result` for polling;
- event lookup by `correlation_id`;
- cancel task -> cancel active run.

Not in v0.4: real LLM planner, DAG, persistent resume, complex memory backend.

Design specification:
[zh/soma-actor.zh.md](zh/soma-actor.zh.md).

## v0.4.1 — actor hardening + release/docs alignment [done]

Before adding LLM planning, close the edge cases in the built actor API and make
the docs match what a user can actually run. Done in
[#73](https://github.com/ZhenchongLi/soma/issues/73) (merged as #74), with the
release inclusion split into the
[#75](https://github.com/ZhenchongLi/soma/issues/75) follow-up (merged as #76).

Target fixes:

- actor quick-start startup contract: either `soma_actor` starts the runtime
  dependencies it needs, or all docs consistently start `soma_runtime` first;
- steps envelope validation: malformed step maps must be rejected or become a
  terminal task failure as data, never a wedged `running` task;
- `ask/3` no-steps behavior: define and test the behavior so no stale waiter is
  left behind;
- `send/2` no-steps behavior: keep it intentional if it represents an accepted
  task awaiting a future decision;
- release contract: decide whether the self-contained release includes
  `soma_actor`; update `rebar.config`, `README.md`, and `docs/release.md`
  accordingly;
- contract docs: keep `docs/contracts/v0.4-test-contract.md`, `README.md`, and
  `docs/usage.md` aligned with the tests;
- static analysis: either make `rebar3 dialyzer` green or document that the
  current merge gate remains `rebar3 eunit && rebar3 ct`.

Outcome — all of the above landed. The actor app now declares `soma_runtime`, so
the quick-start runs after `ensure_all_started(soma_actor)` alone (no README
change needed — it already reads that way); malformed steps are rejected up front
and the actor monitors its run, so a silent run death becomes a terminal `failed`
task instead of a wedged `running` one; `ask/3` on a no-steps envelope returns
`{ok, accepted, TaskId}` without parking a waiter; and the self-contained release
now **includes** `soma_actor` (#75), with `rebar.config`, `docs/release.md`, and a
consistency test kept in lockstep. The merge gate stays `rebar3 eunit && rebar3
ct`; `rebar3 dialyzer` shows only the four pre-existing `soma_lfe_reader` /
`soma_tool_call` warnings (none new).

Done means the actor still proves the process behavior that matters: bad input,
child failure, timeout, and cancellation are data for the task; the actor stays
alive and accepts the next message.

## v0.5 — LLM worker + proposal + policy + budget

Add the first real planning layer without changing `soma_run` into a dynamic
workflow engine. LLMs and rules produce proposals; `soma_actor` validates and
executes them.

Recommended slices:

- `v0.5.1` — `soma_llm_call`: a disposable worker spawned and monitored by
  `soma_actor`, mirroring `soma_run -> soma_tool_call`; no separate
  `soma_llm_call_sup`.
- `v0.5.2` — structured proposal schema: direct reply, run steps, actor message,
  or reject/ask forms; proposals are data, not execution.
- `v0.5.3` — policy gate: validate tool effects, allowed tools, step shape,
  budgets, and actor permissions before execution.
- `v0.5.4` — actor decision loop: no-steps/user-intent envelopes can call rules
  or `soma_llm_call`, then execute an allowed proposal.
- `v0.5.5` — budget and loop limits: exhaustion fails the task, not the actor.
- `v0.5.6` — actor-to-actor messages: preserve `correlation_id` across actors
  and keep the event chain queryable.

Required process proofs:

- an LLM call runs in a distinct worker process;
- LLM timeout/cancel stops the active worker;
- LLM failure reaches `soma_actor` as a message and becomes task data;
- `soma_actor` stays responsive while an LLM call is active;
- policy rejection fails or asks without crashing the actor;
- budget exhaustion fails the task, not the actor;
- `correlation_id` propagates across actor, LLM, run, and actor-to-actor events.

## v0.6 — trace tooling + persistent event store

Before persistent resume, make the event stream useful as a product surface and
as an operational boundary.

Target capabilities:

- a trace helper that renders one `correlation_id` as a readable timeline
  (`actor.* -> llm.* -> run.* -> step.* -> tool.* -> actor.*`);
- an "incident desk" style demo that drives success, failure, timeout, and
  cancellation through one long-lived actor;
- a persistent event store backend behind the existing event-store API;
- event query tests for session, run, and correlation ordering across restarts
  where the backend supports it.

This keeps Soma's strongest property visible: the event stream is the source of
truth, while `ask` and polling are convenience views.

## v0.7 — persistent resume

Add a run journal that survives BEAM restarts. A resumed run replays the event
trail to the last committed step and continues from there.

Open design points:

- idempotency rules for re-running or skipping completed steps;
- what resume means for external CLI tools and stateful tools;
- how actor task state is reconstructed from the event stream;
- how cancellation and timeout are represented during resume.

## v0.8 — DAG / parallel execution

DAG execution is deliberately later. Parallel branches would make `soma_run` a
workflow engine instead of a small, auditable sequential executor.

Only add DAG execution if the actor/planner layer proves it needs it. If it does
land, it must preserve the same invariants:

- every tool invocation still crosses a process boundary;
- branch cancellation kills all active workers and external OS processes;
- branch failure is normalized into bounded task/run data;
- event ordering remains queryable and explainable;
- tests prove process survival, not only output values.

## Packaging

Current release status:

- macOS arm64 self-contained core release: built and verified;
- Linux x86_64 and Linux arm64 release artifacts: pending;
- `soma_actor` release inclusion: done — bundled in the self-contained core
  release (decided and shipped in v0.4.1, #75).

Each executable release artifact remains per target architecture. Native CLI
helpers are packaged for the architecture they run on.

## Rule

Do not add a layer until the layer below it has test coverage for its failure
semantics. In practice: every roadmap item needs tests that assert process
boundaries, terminal states, cancellation, and survival behavior, not just return
values.
