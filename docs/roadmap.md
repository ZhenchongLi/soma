# Roadmap

v0.1 (runtime core), v0.2 (tool manifests + CLI/port adapter), v0.3 (LFE DSL
compile-only layer), v0.4 (the `soma_actor` agent-entity skeleton), v0.5 (the
agent decision layer — LLM-call worker, proposal schema, policy gate,
decision-loop execution, budget, and actor-to-actor messages), and v0.6 (trace
tooling + a durable, opt-in `disk_log` event store) are built and merged. v0.5 ran on a **mock LLM only**, but the real provider has
since landed as **node B.1** (`soma_llm_openai`, smoke-proven against SophNet).
Three tracks now build alongside the v0.X layers: **node B** (the real LLM
provider), the **CLI / daemon** (a single-user `soma` daemon + CLI clients — see
[cli.md](cli.md)), and a **Lisp s-expr message language** for actors/agents (see
[lisp-messages.md](lisp-messages.md)). The sequence below is what comes next.

The important sequencing rule is unchanged: do not add a layer until the layer
below it has test coverage for its failure semantics. With the actor contract
closed, LLM planning landed as a supervised child operation, and the event stream
now both readable (a trace view) and durable (it survives a restart), the next
work is persistent run resume.

## Sequence

```text
v0.1    Erlang/OTP agent runtime                       [done]
v0.2    tool manifests and CLI/port adapter            [done]
v0.3    LFE DSL -> steps                               [done]
v0.4    soma_actor -- agent entity skeleton            [done]
v0.4.1  actor hardening + release/docs alignment       [done]
v0.5    LLM worker + proposal + policy + budget        [done]
v0.6    trace tooling + persistent event store         [done]
v0.7    persistent resume
v0.8    DAG / parallel execution, only if still needed

Active tracks (parallel to v0.7+, building now):
node B  real LLM provider behind the perform_call seam   [B.1 done; B.2 next]
CLI     single-user soma daemon + CLI clients            [CLI.1 in progress]
Lisp    s-expr actor/agent message language (soma_lfe)   [design]
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

## v0.5 — LLM worker + proposal + policy + budget [done]

The first planning layer, added without changing `soma_run` into a dynamic
workflow engine. A (mock) LLM produces proposals; `soma_actor` validates them,
gates them, and executes the approved ones. This is **mock-LLM only** — the call
seam (`soma_llm_call:perform_call/1`) is the single point a real provider grows
into later; there is no provider yet.

Slices (all done):

- `v0.5.1` — `soma_llm_call` [done]: a disposable, monitored, cancellable worker
  the actor owns directly (in `apps/soma_runtime/src/`), mirroring
  `soma_run -> soma_tool_call`; **no** separate `soma_llm_call_sup`. The mock is
  directive-driven (`proposal` / `success` / `slow` / `crash` / `hang`).
- `v0.5.2` — proposal schema [done]: `soma_proposal:normalize/1` (a pure
  validate/normalize boundary in `apps/soma_actor/src/`) tags proposals by `kind`
  — `reply`, `run_steps`, `reject`, `ask`, and (added in v0.5.6) `actor_message`.
  Proposals are data, not execution.
- `v0.5.3` — policy gate [done]: `soma_policy:check/2`, pure, returns
  `allow | {reject, Reason}` against a tool-name allowlist
  (`#{allowed_tools => [atom()] | all}`). Name-based only (no effect-aware gating
  yet).
- `v0.5.4` — actor decision loop [done] (node A): an approved `run_steps` proposal
  now **executes** — the actor starts a `soma_run` and emits `proposal.executed`;
  toolless approved proposals complete with the proposal as the result. New
  statuses `approved` and `rejected`.
- `v0.5.5` — budget and loop limits [done] (node C): a per-task `budget`
  (`#{max_llm_calls => N, max_steps => M}`) checked at the actor's spend points;
  exhaustion fails the task (`{budget_exceeded, _}`), not the actor.
- `v0.5.6` — actor-to-actor messages [done]: an approved `actor_message` proposal
  delivers an envelope to a target actor carrying the sender's `correlation_id`,
  so `by_correlation/2` returns both actors' events. **Delivers P12.**

Required process proofs — all green:

- an LLM call runs in a distinct worker process;
- LLM timeout/cancel stops the active worker;
- LLM failure reaches `soma_actor` as a message and becomes task data;
- `soma_actor` stays responsive while an LLM call is active;
- policy rejection fails without crashing the actor;
- budget exhaustion fails the task, not the actor;
- `correlation_id` propagates across actor, LLM, run, and actor-to-actor events.

Outcome — the agent decision layer is built and merged, mock-LLM only. The full
proof→test map is in
[contracts/v0.5-test-contract.md](contracts/v0.5-test-contract.md); the v0.4
contract's P12 and P13 are now delivered. The **one remaining deferred proof is
P14** (the policy proactively asks a human before executing) — there is no
human-in-the-loop ask path yet.

Real-provider planning (a real `node B` behind the `perform_call/1` seam) and an
effect-aware policy gate remain future work beyond this layer.

## v0.6 — trace tooling + persistent event store [done]

Before persistent resume, make the event stream useful as a product surface and
as an operational boundary. The event log was always mandatory; this layer makes
it **readable** (a trace view over one `correlation_id`) and **durable** (it
survives a BEAM restart) without changing the `by_*` query API any caller already
uses.

Slices (all done):

- `v0.6.1` — `soma_trace` [done]: read-side trace tooling in
  `apps/soma_event_store/src/`. `soma_trace:timeline/1` is pure — it renders a
  list of event maps as a readable, timestamp-ordered timeline, one line per
  event; `soma_trace:render/2` is `by_correlation/2` then `timeline/1`, so one
  `correlation_id` reads back as `actor.* -> llm.* -> run.* -> step.* -> tool.*
  -> actor.*`. Read-only, depends on nothing above `soma_event_store`.
- `v0.6.2` — durable `soma_event_store` [done]: an opt-in `disk_log` backend
  behind the existing API. `start_link/1` with `#{log => Path}` opens a `halt`
  `disk_log`; `append/2` writes the normalized event to the log *and* the
  in-memory index; `init/1` replays the log on boot to rebuild the index,
  tolerating a truncated tail (an unclean shutdown's half-written term is treated
  as end-of-log). `start_link/0` stays in-memory, byte for byte. Events survive a
  BEAM restart. This establishes the principle the next layer leans on: **the
  durable log is the source of truth, the in-memory index is a rebuildable
  cache**. Proofs in
  [contracts/v0.6-test-contract.md](contracts/v0.6-test-contract.md).
- `v0.6.3` — env-wired persistence [done]: `soma_sup` chooses the store's mode
  from app env — `application:get_env(soma_runtime, event_store_log, undefined)`:
  a path starts the persistent store (`start_link/1`), unset keeps the in-memory
  default (`start_link/0`) for dev and tests. The prod release becomes durable by
  setting that env (a `sys.config` example is in `docs/release.md`).

Outcome — trace tooling, a durable `disk_log` event store, and env-wired
persistence are built and merged. The event stream is now both a readable
operational view (`soma_trace`) and a durable record that survives a restart,
behind the same query API; the "durable log = source of truth, in-memory index =
rebuildable cache" principle is the foundation v0.7's persistent resume builds
on. The one piece deferred within this layer is the **"incident desk" demo** (an
example driving success / failure / timeout / cancellation through one long-lived
actor) — not built.

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

## node B — real LLM provider (接真模型)

The real provider behind the v0.5.1 call seam (`soma_llm_call:perform_call/1`), so
the decision loop can run against a real model instead of the mock. The mock stays
the gate default; real calls are opt-in and **off the test gate** (no network in
`rebar3 eunit` / `ct`).

- `node B.1` — provider [done] (#101): `soma_llm_openai` (in
  `apps/soma_runtime/src/`) calls an OpenAI-compatible chat-completions API and
  turns the model's text into a `reply` proposal; `perform_call/1` routes to it for
  real-provider opts. Pure request-build / response-parse tests on the gate; an
  opt-in `soma_llm_smoke:run/0` (key from `SOMA_LLM_API_KEY`) proves it live
  against SophNet (validated: DeepSeek-V4, Qwen3.6 + the `enable_thinking` toggle).
- `node B.2` — actor wiring [next]: select the real provider from the actor's
  `model_config` so a task runs end to end against a real model. The brain
  `soma ask` needs this.
- Later: structured proposals from the model (`run_steps` / tool-use planning, not
  just `reply`) and an effect-aware policy gate.

Provider `base_url` / `model` live in local config; the **API key is only ever
read from an env var / a gitignored file, never committed**.

## CLI — single-user soma daemon + CLI

Expose soma as a **CLI** that your own autonomous agents (Claude Code, Codex) shell
out to — soma as the supervised, auditable execution substrate they delegate to.
Architecture: a long-lived **daemon** (runtime + actors + the durable event store)
with thin CLI clients over a local **Unix socket**. Single-user / trusted-local
(no cross-client auth). Not MCP. Full design: [cli.md](cli.md).

- `CLI.1` — daemon socket server [in progress] (#102): the Unix-socket listener +
  length-prefixed JSON protocol + the `run` handler (supervised run → result), with
  stale-socket cleanup, atomic single-winner bind, and cancel-on-disconnect.
- `CLI.1b` — the `soma daemon` boot command + the thin `soma run` client binary.
- `CLI.2` — `soma ask` (intent → real LLM → proposal → policy → execute); needs
  node B.2.
- `CLI.3` — `soma status` / `soma cancel` / `soma trace` clients, `--detach`,
  auto-start.

## Lisp — s-expr actor/agent message language

Make Lisp s-expressions the message / interchange language between actors and
agents — **Lisp at the edges, Erlang at the core** (the execution substrate and
BEAM message-passing stay Erlang/OTP). Turns the v0.3 `soma_lfe` parser from an
orphan into the message parser. A Lisp message is homoiconic — data or an
executable plan in one language. Full design: [lisp-messages.md](lisp-messages.md).

- `L.1` — Lisp envelope: `soma_lfe` parses `(msg …)` → the internal envelope;
  `soma_actor:send` / `ask` accept a Lisp string (additive — map envelopes still
  work).
- `L.2` — actor-to-actor Lisp messages (correlation_id preserved, per v0.5.6).
- `L.3` — Lisp proposals: the LLM emits Lisp, parsed into a proposal — coherent
  once the whole system speaks Lisp.
- `L.4` — Lisp audit: the event store records the s-expr form; `soma_trace`
  renders a correlation chain as readable, replayable Lisp.
- `L.5` — self-repair: a parse-failure → LLM-repair(source, diagnostics) →
  re-parse loop, bounded by the v0.5.5 budget. The repaired message re-enters the
  full normalize + policy + budget pipeline — a second chance, **never a bypass**.

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
