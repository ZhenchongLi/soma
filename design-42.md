# [v0.3] Add contract tests and docs for LFE DSL

## Current state

The `soma_lfe` app exists and compiles. It has three modules:

- `soma_lfe_reader` — a hand-written scanner + parser that turns LFE source text into Erlang terms (atoms, binaries, integers, nested lists).
- `soma_lfe_parser` — walks the raw form list and produces `{ok, #{run => #{steps => [...]}}}` or `{error, [diagnostic()]}`. It validates duplicate step ids, unknown/forward `from_step` references, non-positive `timeout_ms`, and unknown forms. Errors are accumulated across steps rather than stopping at the first bad one.
- `soma_lfe` — the public boundary. `compile/2` threads source through the reader then the parser. `compile_file/2` reads the file first.

Four EUnit modules in `apps/soma_lfe/test/` already cover much of the compiler surface:

- `soma_lfe_tests` — app file presence, `compile/2` return shapes, and two layer-separation assertions (runtime does not depend on `soma_lfe`; `compile/2` does not start `soma_sup`).
- `soma_lfe_parse_tests` — happy-path parse, multiple top-level forms, non-`run` top-level form, unknown step child form, oversized atom guard, and a runtime-isolation check.
- `soma_lfe_compile_tests` — the three-step `file_read → echo → file_write` demo, both `from_step` shapes, `timeout_ms` omission, and the `start_run/2` contract shape.
- `soma_lfe_validation_tests` — duplicate step id, forward and unknown `from_step`, invalid `timeout_ms`, unknown form, multiple-diagnostic accumulation, and the `soma_sup` non-start guard.

What does not yet exist:

- **End-to-end runtime contract tests** that take compiled DSL output and feed it to `soma_agent_session:start_run/2`, confirming the runtime's process-behaviour guarantees hold unchanged (distinct worker pids, full event trail, failure/timeout/cancel semantics, session survival, fresh run after terminal state). These mirror what `soma_run_happy_path_SUITE` and `soma_run_failure_SUITE` prove for hardcoded steps, but starting from DSL source.
- **`docs/lfe-dsl.md`** — the syntax reference, the step-list contract, the demo example, `from_step` forms, diagnostics, and explicit non-goals.
- Updates to `README.md` and `docs/roadmap.md` once the contract is green.

The `soma_lfe` app declares only `kernel` and `stdlib` as dependencies — it has no compile-time or runtime dependency on `soma_runtime`. That constraint must stay.

## Approach

### New CT suite: `soma_lfe_runtime_SUITE`

Add `apps/soma_runtime/test/soma_lfe_runtime_SUITE.erl`. It lives in `soma_runtime`'s test directory because it needs `soma_runtime` running (`application:ensure_all_started(soma_runtime)` in `init_per_testcase`). It calls `soma_lfe:compile/2` to get the step list, then passes the steps to `soma_agent_session:start_run/2`. That is the only bridge. No extra integration code is needed.

Each test case follows the same shape the existing CT suites use: start `soma_runtime`, start a session via `soma_agent_session:start_link/1`, compile DSL source, call `start_run/2` with the compiled steps, poll `soma_event_store:by_run/2` for terminal events, assert process/event guarantees.

The suite needs `soma_lfe` on the code path. Since the rebar3 umbrella already compiles all apps, this is automatic — no new dependency declaration is needed in `soma_runtime.app.src` (the test driver calls `soma_lfe:compile/2` at test time, not at application start).

Seven runtime contract cases:

1. **Demo compiles and runs to `completed`** — compile the three-step `file_read → echo → file_write` DSL source, pass the steps to `start_run/2`, wait for `run.completed`. Assert the output file holds the input bytes.
2. **Compiled demo produces the normal event trail** — same run as above; assert the run-scoped trail is `run.accepted → run.started → [step.started → tool.started → tool.succeeded → step.succeeded] × 3 → run.completed` in that order.
3. **Each tool call has a distinct worker pid** — compile a two-step echo run, assert the `tool_call_pid` values on `tool.started` events differ from each other and from the run pid. Confirms `soma_tool_call` is still in the path.
4. **Compiled `fail` step fails the run without killing the session** — compile a one-step run using `fail` (mode error), wait for `run.failed`, assert the session pid is still alive and reports `failed`.
5. **Compiled `sleep` step can be timed out** — compile a step with `sleep` and a short `timeout_ms`, wait for `run.timeout`, assert `run.completed` never appears.
6. **Compiled `sleep` step can be cancelled** — compile a slow `sleep` step, start the run, wait for `tool.started`, send `{cancel_run, RunId}` to the session, wait for `run.cancelled`.
7. **Session starts a fresh run after DSL-sourced failure, timeout, or cancellation** — after each of the three terminal states above, call `start_run/2` with a plain compiled echo step and assert the second run reaches `run.completed`.

### Existing EUnit coverage (no new files needed)

The compiler failure criteria — duplicate ids, unknown `from_step`, forward `from_step`, invalid `timeout_ms`, unknown forms, and no runtime side effects on failure — are already covered by `soma_lfe_validation_tests` and `soma_lfe_parse_tests`. No new EUnit file is needed for those.

The "compile failure does not emit runtime events" criterion is already covered by `test_invalid_dsl_does_not_start_run` in `soma_lfe_validation_tests` and `test_parse_does_not_start_runtime` in `soma_lfe_parse_tests`.

### New doc: `docs/lfe-dsl.md`

Cover in order: the v0.3 syntax (forms accepted: `run`, `step`, `args`, `timeout_ms`, `from_step`); the step-list shape the compiler emits and the contract that shape must satisfy for `start_run/2`; the `file_read → echo → file_write` example with the exact DSL source and the compiled steps side by side; both `from_step` reference forms (bare map and field-level tuple); diagnostic codes and what triggers each; and explicit non-goals (no LLM planner, MCP, DAG, loops, branches, variables, arbitrary Lisp eval, persistent resume, new runtime event semantics).

### Doc updates

Update `README.md` to reflect v0.3 as built — add a short description of the LFE DSL layer and reference `docs/lfe-dsl.md`. Update `docs/roadmap.md` to mark v0.3 done once the suite is green.

## Acceptance criteria → tests

| # | Criterion | Test module | Test name |
|---|-----------|-------------|-----------|
| R1 | DSL demo compiles and runs through `start_run/2` to `run.completed` | `soma_lfe_runtime_SUITE` | `test_dsl_demo_runs_to_completed` |
| R2 | Compiled demo produces the normal runtime event trail | `soma_lfe_runtime_SUITE` | `test_dsl_demo_event_trail` |
| R3 | Each tool call has its own worker pid; DSL does not bypass `soma_tool_call` | `soma_lfe_runtime_SUITE` | `test_dsl_tool_calls_have_distinct_pids` |
| R4 | Compiled `fail` step fails the run without killing the session | `soma_lfe_runtime_SUITE` | `test_dsl_fail_step_fails_run_session_survives` |
| R5 | Compiled `sleep` step can still be timed out by the runtime | `soma_lfe_runtime_SUITE` | `test_dsl_sleep_step_times_out` |
| R6 | Compiled `sleep` step can still be cancelled by the runtime | `soma_lfe_runtime_SUITE` | `test_dsl_sleep_step_cancels` |
| R7 | Session starts a fresh run after DSL-sourced failure, timeout, or cancellation | `soma_lfe_runtime_SUITE` | `test_dsl_session_recovers_after_terminal_state` |
| C1 | Duplicate step ids fail compilation | `soma_lfe_validation_tests` | `test_duplicate_step_id_returns_diagnostic` |
| C2 | Unknown `from_step` references fail compilation | `soma_lfe_validation_tests` | `test_unknown_from_step_returns_diagnostic` |
| C3 | Forward `from_step` references fail compilation | `soma_lfe_validation_tests` | `test_forward_from_step_returns_diagnostic` |
| C4 | Invalid `timeout_ms` values fail compilation | `soma_lfe_validation_tests` | `test_invalid_timeout_returns_diagnostic` |
| C5 | Unknown DSL forms fail compilation | `soma_lfe_validation_tests` | `test_unknown_form_returns_diagnostic` |
| C6 | Compile failure does not start a run and does not emit runtime events | `soma_lfe_validation_tests` | `test_invalid_dsl_does_not_start_run` |
| D1 | `rebar3 eunit` and `rebar3 ct` pass | build gate | (all above) |
| D2 | Docs describe the compiler as a compile-only layer | `docs/lfe-dsl.md` | (doc review) |
| D3 | Proof-to-test mapping is clear enough that DSL cannot be mistaken for a runtime | `docs/lfe-dsl.md` + this design | (doc review) |

### Call chains

**R1–R7 (runtime contract tests)**

Call chain: test calls `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` → `soma_lfe_parser:parse_run/1`, then passes the resulting steps to `soma_agent_session:start_run/2` → `soma_run` (gen_statem) → `soma_tool_call` (worker, per step) → tool module or port.

Test entry: `soma_lfe:compile/2` then `soma_agent_session:start_run/2`. No layer is bypassed. The test starts at the public compiler API and continues through the real session/run/tool-call chain.

**C1–C6 (compiler failure tests)**

Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` → `soma_lfe_parser:parse_run/1` → `validate_steps/1` → diagnostics returned; no runtime call made.

Test entry: `soma_lfe:compile/2` (direct call, no runtime involved).

## Risks & trade-offs

**`soma_lfe` on the test code path without a declared OTP dependency.** The `soma_runtime` app does not list `soma_lfe` as a dependency and should not — the whole point is that the compiler and runtime are separate layers. The CT suite calls `soma_lfe:compile/2` at test time. This works because rebar3 compiles all umbrella apps before running tests, so the beam files are present. If someone moves `soma_lfe` to a separate repo or changes the umbrella structure, the CT suite will fail with a `undef` at test time rather than at compile time. That is the right failure mode, but it is worth noting.

**R7 uses three separate runs in one test case.** The alternative is three separate cases (`test_dsl_session_recovers_after_failure`, etc.). Three cases match the pattern the existing suites use (`test_session_runs_new_run_after_failed`, `_after_timeout`, `_after_cancelled` are distinct cases in `soma_run_failure_SUITE`). Splitting gives clearer failure attribution. The design leaves the split decision to Dev but notes the existing suites use separate cases.

**Existing EUnit coverage already closes most compiler criteria.** The C-series rows above map to existing test functions, not new ones. If a future refactor renames those functions without updating this doc, the mapping drifts. The gate catches deleted cases but not renames. This is the same drift caveat that `docs/v0.2-test-contract.md` carries.

**The `test_dsl_demo_event_trail` case asserts an exact ordered trail.** Any change to how `soma_run` emits events (e.g., adding a new event type between existing ones) will break this case. That is intentional — the test is a pin, not just a membership check.
