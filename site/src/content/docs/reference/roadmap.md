---
title: Roadmap
description: Where Soma is and what comes next — the v0.1–v0.7 layers (all built and merged, including boot auto-resume), the parallel real-provider, CLI, and Lisp-message tracks, and the sequencing rule that gates every new layer on the one below it having failure-semantics tests.
---

v0.1 (runtime core), v0.2 (tool manifests + CLI/port adapter), v0.3 (LFE DSL
compile-only layer), v0.4 (the `soma_actor` agent-entity skeleton), v0.5 (the
agent decision layer — LLM-call worker, proposal schema, policy gate,
decision-loop execution, budget, and actor-to-actor messages), v0.6 (trace
tooling + a durable, opt-in `disk_log` event store), and v0.7.1-v0.7.5
(persistent resume journal, reconstruction, plan, manual executor, and boot
auto-resume) are built and merged. The parallel tracks have also moved:
**node B.1/B.2** landed the OpenAI-compatible provider and actor `model_config`
wiring, with actor-level planning mode behind `plan => true`; the **CLI /
daemon** modules now expose a single-user Unix-socket Lisp wire for
run/ask/status/trace/cancel/detach; and the **Lisp s-expr message language** has
L.1-L.5 tests for envelopes, actor-to-actor delivery, proposals, audit rendering,
and bounded repair. The sequence below is the current state and remaining work.

The important sequencing rule is unchanged: do not add a layer until the layer
below it has test coverage for its failure semantics. With the actor contract
closed, LLM planning landed as a supervised child operation, and persistent
resume now covers manual resume plus boot auto-resume, the next runtime work is
outside the resume layer.

## Sequence

```text
v0.1    Erlang/OTP agent runtime                       [done]
v0.2    tool manifests and CLI/port adapter            [done]
v0.3    LFE DSL -> steps                               [done]
v0.4    soma_actor -- agent entity skeleton            [done]
v0.4.1  actor hardening + release/docs alignment       [done]
v0.5    LLM worker + proposal + policy + budget        [done]
v0.6    trace tooling + persistent event store         [done]
v0.7    persistent resume                              [done — journal + reconstruct + executor + boot auto-resume]
v0.8    DAG / parallel execution, only if still needed

Shipped tracks (parallel to v0.7+):
node B  real LLM provider behind the perform_call seam   [done — provider + actor planning + CLI/config planning surface]
CLI     single-user soma daemon + CLI clients            [done — packaged `soma` command + auto-start]
Lisp    bounded Soma Lisp v1 public task surface          [done] L.1-L.5 + task form
tools   tool abstraction track                            [done — T.1 manifest v2 + catalog/0; T.2 config tools; catalog-fed planning prompt; T.4 ask_actor]
        live config-tool management                       [done — soma tool register + soma tool list + soma tool remove]
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
gates them, and executes the approved ones. This layer was built against the
mock LLM; the mock remains the hermetic gate default, while node B adds the real
provider path behind the same seam.

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

Outcome — the agent decision layer is built and merged, mock-LLM on the gate. The
v0.4 contract's P12 and P13 are now delivered. The **one remaining deferred proof
is P14** (the policy proactively asks a human before executing) — there is no
human-in-the-loop ask path yet.

A human-in-the-loop ask path and an effect-aware policy gate remain future work
beyond this layer.

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
  cache**.
- `v0.6.3` — env-wired persistence [done]: `soma_sup` chooses the store's mode
  from app env — `application:get_env(soma_runtime, event_store_log, undefined)`:
  a path starts the persistent store (`start_link/1`), unset keeps the in-memory
  default (`start_link/0`) for dev and tests. The prod release becomes durable by
  setting that env (a `sys.config` example is in the Release guide).

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

Add a run journal that survives BEAM restarts, then let a resumed run replay the
event trail to the last committed step and continue from there.

- `v0.7.1` — resume journal + read-only reconstruction [done] (#129): `soma_run`
  journals each run into `run.started` as `#{steps, run_options}`, where
  `run_options` is an allowlist of resume-safe metadata (`run_id`, optional
  `session_id`, optional `correlation_id`) and never process-local values or
  secrets. `soma_run_resume:reconstruct/2` reads the durable trail through
  `soma_event_store:by_run/2` and rebuilds run progress — journaled steps,
  durable options, committed outputs by step id, the first uncommitted step, and
  terminal status — strictly read-only (no event append, no run child started).
  It rejects a trail with no usable `run.started` journal, or one whose committed
  step id is absent from the journal.

- `v0.7.2` — the `soma_run` resume seam [done] (#162): `init/1` accepts a `pending`
  suffix + a pre-seeded `outputs` map, so a run starts mid-list; a resume start
  emits `run.resumed` instead of re-journaling `run.started`; a normal start is
  unchanged.
- `v0.7.3` — the resume plan [done] (#165): `soma_run_resume_plan:plan/2` (pure)
  returns `{resume, …}` / `{unsafe, StepId}` / `{terminal, Status}` /
  `nothing_to_do` / `{error, _}`. It gates on `terminal_status` and classifies an
  in-flight step via the tool registry's `effect`/`idempotent`.
- `v0.7.4` — the resume executor [done] (#167): `soma_run_resume_executor:resume/3`
  (reconstruct → plan → act) starts a resumed run under `soma_run_sup` owned by a
  live session, or lands it terminal `failed {resume_unsafe, StepId}`. **The
  decided idempotency rule is fail-safe: never re-run a non-idempotent `state`
  step that was in flight** — the run fails clearly rather than risk doubling an
  irreversible side effect, and the fail-safe is sticky.
- `v0.7.5` — auto-resume on boot [done] (#198): the durable event store exposes
  interrupted run discovery (`run.started`, no terminal event), excludes terminal
  runs, and `soma_runtime` boot hands interrupted runs to the existing resume
  executor. A between-steps run resumes and emits `run.resumed`; a non-idempotent
  in-flight `state` step fails clearly with `{resume_unsafe, StepId}`.

Still open:

- Later relaxations of the fail-safe rule: a per-tool resume policy, or a
  compensate-then-retry hook for non-idempotent steps.

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

## node B — real LLM provider

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
- `node B.2` — actor wiring [done] (#119): an actor's `model_config` can select
  `provider => openai_compat`; `soma_actor:build_call_opts/2` derives provider
  call opts from the envelope payload, routes through `soma_llm_call`, and keeps
  the API key out of emitted events. Gate tests use a fixed-response seam, not a
  real socket.
- actor-level planning mode [done]: a real-provider `model_config` carrying
  `plan => true` adds a system instruction, reads the provider's reply content as
  a Lisp `(run-steps ...)` proposal, sends it through `soma_lfe:compile/2`,
  `soma_proposal:normalize/1`, policy, and budget, then runs approved steps. Gate
  tests use fixed responses and open no model socket.
- planning surface productized [done]: `~/.soma/config` and the CLI drive
  real-provider planning mode through the daemon.
- Later: an effect-aware policy gate.

Provider `base_url` / `model` live in local config; the **API key is only ever
read from an env var / a gitignored file, never committed**.

## CLI — single-user soma daemon + CLI

Expose soma as a **CLI** that your own autonomous agents (Claude Code, Codex) shell
out to — soma as the supervised, auditable execution substrate they delegate to.
Architecture: a long-lived **daemon** (runtime + actors + the durable event store)
with thin CLI clients over a local **Unix socket**. Single-user / trusted-local
(no cross-client auth). Not MCP. See the [CLI guide](/guides/cli/).

- `CLI.1` / `CLI.1b` — daemon socket server + Lisp `run` wire [done]: Unix-domain
  listener, length-prefixed s-expr frames, stale-socket cleanup, single-winner
  bind, cancel-on-disconnect, `soma_cli:daemon/1`, and `soma_cli:run/1`.
- `CLI.2` — `soma ask` [done on the module/server path]: intent → LLM proposal →
  policy → result over the same Lisp wire, mock on the gate and real-provider by
  daemon/actor config.
- `CLI.3` / follow-up — read/manage commands [done on the module/server path]:
  `soma_cli:status/1`, `trace/1`, `cancel/1`, plus detached run support and
  cancel-by-id through `soma_cli_task_registry`.
- `CLI.8` — `~/.soma/config` (TOML) → daemon `model_config` [done]: a hand-rolled
  minimal TOML reader builds the real-provider config at daemon boot, with the API
  key only from `SOMA_LLM_API_KEY` env, so `soma ask` can answer from a real model.
- `CLI.9` — `soma stop` [done]: an in-band `(stop)` request tears the daemon down
  (closes the listen socket, cancels in-flight runs, unlinks the socket file),
  distinct from relx's node-control `stop`.
- `CLI.6` — packaged `soma` command [done]: the OTP release is named `somad` (so
  `bin/somad` is node control) and ships `bin/soma`, a wrapper that dispatches
  `run` / `ask` / `status` / `cancel` / `trace` / `stop` / `daemon` to
  `soma_cli_main` over the bundled ERTS — no separate Erlang install, no name
  collision. `soma daemon` blocks until `soma stop`. Verified by an end-to-end
  release smoke test.
- `CLI.7` — auto-start [done]: a client verb (`run` / `ask` / `status` / `cancel`
  / `trace`) probes the socket with `soma_cli:ping/1` and, finding no daemon,
  launches `soma daemon` detached and waits for it before running — so there is no
  separate `soma daemon` ritual. A lost auto-start race is harmless: only one
  daemon wins the kernel bind and `daemon_foreground/1` returns on the others.
  **The CLI track is complete.**

## Lisp — s-expr actor/agent message language

Make Lisp s-expressions the message / interchange language between actors and
agents — **Lisp at the edges, Erlang at the core** (the execution substrate and
BEAM message-passing stay Erlang/OTP). Turns the v0.3 `soma_lfe` parser from an
orphan into the message parser. A Lisp message is homoiconic — data or an
executable plan in one language.

- `L.1` — Lisp envelope [done]: `soma_lfe` parses `(msg …)` → the internal envelope;
  `soma_actor:send` / `ask` accept a Lisp string (additive — map envelopes still
  work).
- `L.2` — actor-to-actor Lisp messages [done] (correlation_id preserved, per v0.5.6).
- `L.3` — Lisp proposals [done]: the LLM emits Lisp, parsed into a proposal — coherent
  once the whole system speaks Lisp.
- `L.4` — Lisp audit/rendering [done]: the event store records the s-expr form; `soma_trace`
  renders a correlation chain as readable, replayable Lisp.
- `L.5` — self-repair [done]: a parse-failure → LLM-repair(source, diagnostics) →
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
