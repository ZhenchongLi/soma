# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

The **v0.1–v0.4 layers are built and merged** — all green on `main` (EUnit 110, CT 134), Erlang/OTP 29 + rebar3 3.27. `README.md` remains the authoritative spec — read it before extending anything; the sections below summarize what shapes day-to-day work.

**v0.1** (the runtime core): the in-memory event store; the tool behaviour + registry + the five v0.1 tools; the session/run/tool-call execution core (sequential steps, `from_step` wiring, the `file_read → echo → file_write` demo); and the full failure semantics (error, crash isolation, timeout, cancellation). All ten proofs of the v0.1 test contract pass.

**v0.2** (tool manifests + CLI/port adapter, issues #14–#23): a normalized tool **manifest** contract (`docs/tool-manifest.md`) validated by `soma_tool_manifest:normalize/1`; the registry upgraded from `name => module` to `name => descriptor` (`resolve_descriptor/1`), with built-ins registering through their own `manifest/0`; and a one-shot **`cli` adapter** in `soma_tool_call` that launches an external executable through a port (executable + argv, no shell) with real timeout/cancel teardown of the external OS process, normalized failures, a minimal environment, and a fixed cwd. The v0.2 process-behaviour proof set is published in `docs/contracts/v0.2-test-contract.md`.

**v0.3** (LFE DSL compile-only layer, issues #38–#42): a `soma_lfe` app — `soma_lfe:compile/2` parses a constrained Lisp-flavored grammar into the exact step-list maps `start_run/2` accepts, returning `{ok, #{run => #{steps => Steps}}}` or `{error, [Diagnostic]}`. Compile-only: no processes, no events, one-way dependency (`soma_runtime` never imports `soma_lfe`). Published in `docs/contracts/v0.3-test-contract.md`.

**v0.4** (the `soma_actor` agent-entity skeleton, issues #53–#70): a new `apps/soma_actor` app — a long-lived `gen_statem` actor under its own `soma_actor_sup` (`simple_one_for_one`). It takes a message envelope via `send/2` / `ask/3`, mints `task_id` / `correlation_id`, emits `actor.*` events, and on a steps envelope starts a `soma_run` it **owns directly** (`session_pid => self()`, no `soma_agent_session` in its path). It records the run's result or survives its failure/timeout/cancel as data, exposes a result model (`ask` reply + `get_task_status` / `get_task_result` polling), `cancel/2`, and `soma_event_store:by_correlation/2` for full-chain lookup. `soma_run` gained one additive opt — an optional `correlation_id`, stamped on every run event. **Fixed-rule decisions, no real LLM** (planner + policy gate are v0.5). Twelve proofs (P1–P11, P15) green; published in `docs/contracts/v0.4-test-contract.md`. One-way dependency: `soma_actor` may use `soma_runtime` / `soma_event_store`; the runtime never imports `soma_actor`. **There is no `soma_llm_call_sup`** — when v0.5 adds `soma_llm_call`, the actor spawns and monitors it directly, mirroring `soma_run → soma_tool_call`.

What remains for the *full* README "Done Means": the Linux x86_64 + arm64 release packaging (build/CI work, not runtime logic) — macOS arm64 is built and verified.

## What Soma is

An Erlang/OTP-native agent runtime. The core thesis: an agent run is **not a function that calls tools in a loop** — it's a supervised OTP process tree. Erlang/OTP provides the execution semantics (timeouts, cancellation, monitoring, crash isolation, restart policy); the step list only says *what* to run.

The mental model is the **actor model + OTP supervision**: every session, run, and tool call is an actor (isolated process, private mailbox, message-passing only), and OTP's supervision/monitors add the fault-tolerance layer that is the actual thesis. Don't let future work collapse a run back into an in-process loop, or reach for defensive `try/catch` where a process boundary + monitor is the design.

v0.1 is runtime-only: sequential steps, supervised tool calls, real timeout/cancellation, an in-memory event store, and a Linux x86_64 + arm64 release. Explicitly **out of scope for v0.1**: DAG parallelism, distributed Erlang, complex planning, retries beyond a simple policy, and any hard dependency on a real LLM. Don't pull roadmap items (LFE DSL, MCP, LLM planner, DAG) into v0.1.

## Architecture (the load-bearing parts)

Supervision tree:

```
soma_sup                                        (apps/soma_runtime)
  ├── soma_event_store
  ├── soma_tool_registry
  ├── soma_session_sup → soma_agent_session   (gen_server, long-lived)
  └── soma_run_sup     → soma_run             (gen_statem, per-run)
                            └── soma_tool_call  (per-tool-call worker, disposable)

soma_actor_sup                                  (apps/soma_actor; simple_one_for_one; v0.4)
  └── soma_actor                              (gen_statem, long-lived agent entity)
```

`soma_actor` is a separate app above the runtime (one-way dependency). It starts runs **directly** under `soma_run_sup` as their owner — there is no session in its path — and learns each run's outcome from the `{run_completed | run_failed | run_timeout | run_cancelled, RunId, ...}` message `soma_run` already sends to its `session_pid`. See the v0.4 paragraph above and `docs/zh/soma-actor.zh.md`.

- **`soma_agent_session`** (`gen_server`, long-lived): owns `session_id` and session metadata, accepts run requests, starts `soma_run` under `soma_run_sup`, tracks active runs, and must **survive failed/timed-out/cancelled runs**. It never executes tool logic directly.
- **`soma_run`** (`gen_statem`, short-lived): owns one execution attempt — step cursor, step results, active tool-call pid, run timeout timer, cancellation, and event emission. Terminal states are explicit: `completed | failed | cancelled | timeout`. It starts each tool call as a monitored worker; **a tool crash is data for the run, not a crash of the session**. Steps are iterated inside `soma_run` itself — its `executing` / `waiting_tool` states are the step cursor, so there is no separate per-step process (the design's `soma_step` was folded into the state machine); `soma_tool_call` is the only worker it spawns. The per-step timeout is a `state_timeout`; a crashing tool arrives as the worker monitor's `'DOWN'`.
- **`soma_tool_call`** (disposable worker): executes exactly one tool invocation, returns a result/error message to `soma_run`, then dies. It branches on the resolved descriptor's `adapter`: an `erlang_module` tool runs `Module:invoke/2` in-BEAM; a `cli` tool launches an external executable through a port (`open_port({spawn_executable, …})`, executable + argv, no shell) and reports the spawned external **OS pid** up to `soma_run` — because `exit(WorkerPid, kill)` is untrappable, the longer-lived run holds the pid and kills the external process (shell-free, via `os:find_executable("kill")`) on timeout/cancel, so a hanging cli program cannot outlive its run.

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

**v0.2 manifests + adapters.** A tool now also has a **manifest** — its `describe/0` metadata plus an `adapter` and adapter-specific fields — validated and normalized by `soma_tool_manifest:normalize/1` into the descriptor the registry stores (so the registry holds `name => descriptor`, resolved via `resolve_descriptor/1`). Two adapters exist: `erlang_module` (the in-BEAM built-ins, each exposing `manifest/0` = `(describe())#{adapter => erlang_module, module => ?MODULE}`) and `cli` (`#{adapter => cli, executable, argv}`) for one-shot external executables. The `cli` execution protocol — input delivered as the **final argv argument** (Erlang ports can't half-close stdin), stdout captured as the step output, exit 0 = success — is documented in `docs/tool-manifest.md`. A packaged sample helper lives at `apps/soma_tools/priv/cli/soma_sample_upper`, referenced at runtime via `code:priv_dir/1`. CLI failures normalize to named bounded `{error, _}` (missing/non-executable, nonzero exit with status, output over a byte limit); the cli child gets a minimal env (only `PATH`) and a fixed cwd; argv is never shell-interpreted.

## Steps (not an IR yet)

v0.1 uses a deliberately small step-list format — a list of maps with `id`, `tool`, `args` (with simple `from_step` references to prior output), and `timeout_ms`. The executor is strictly sequential: validate step → start tool call → wait for result → record event → next step. No branching, loops, DAG, or variables. The runtime must not depend on where steps came from (future planners all compile down to this format).

## The test contract is the priority

Per `README.md`, the v0.1 end-to-end test (demo: `file_read -> echo -> file_write`) matters more than adding integrations. Tests must **assert process survival, not just return values**. The ten required proofs: session starts; run accepted; steps run sequentially; each tool call has its own process; events emitted; a failing tool fails the run; a crashed tool doesn't kill the session; a hanging tool times out; cancelling a run stops the active tool; the session can start another run afterward.

All ten are implemented and green: the happy-path proofs live in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl` and the failure-mode proofs in `soma_run_failure_SUITE.erl`. Hold this bar (real process-survival assertions) for any extension.

v0.2 extends the contract without weakening it. Its process-behaviour proof set — manifests validate before registration; built-ins run through manifests; a `cli` tool succeeds through the real session → run → tool-call layers with a distinct worker pid and the same event trail; nonzero / missing / hanging / cancelled `cli` runs fail-or-stop (and the external OS process is verifiably gone) while the session survives and runs again — is published in `docs/contracts/v0.2-test-contract.md`, each proof mapped to the suite and case that proves it (`soma_cli_adapter_SUITE`, `soma_cli_lifecycle_SUITE`, `soma_cli_failure_SUITE`, `soma_cli_packaging_SUITE`, `soma_tool_manifest_tests`, `soma_tool_registry_tests`). Same bar applies.

## Build commands

The toolchain is installed (Erlang/OTP 29, rebar3 3.27) and the rebar3 umbrella is in place (`apps/soma_runtime`, `apps/soma_tools`, `apps/soma_event_store`, `apps/soma_lfe`, `apps/soma_actor`). The relay merge gate runs `rebar3 eunit && rebar3 ct`. Commands:

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
