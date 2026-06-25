# v0.4: harden soma_actor startup, step validation, ask/no-steps, release docs

## Current state

The v0.4 `soma_actor` slice is merged and green (EUnit 110, CT 134), but four
spots where the docs, the startup contract, and the task model don't line up are
uncovered.

1. **Startup.** `apps/soma_actor/src/soma_actor.app.src` lists
   `{applications, [kernel, stdlib]}`. But `maybe_start_run/4` (soma_actor.erl
   line 245) calls `soma_run_sup:start_run/1`. After
   `application:ensure_all_started(soma_actor)` alone, `soma_run_sup` is not
   running, so a steps envelope crashes the actor with `noproc`. The README
   quickstart (README.md line 121) shows exactly this path. The existing CT
   suite hides the gap because `init_per_testcase` calls
   `application:ensure_all_started(soma_runtime)` by hand before each
   run-integration case (soma_actor_SUITE.erl line 207).

2. **Malformed steps.** `validate_envelope/1` (soma_actor.erl line 215) only
   checks that `type` and `payload` exist. A step map missing `id` passes
   validation, starts a run, and crashes `soma_run:executing/3` at
   `maps:get(id, Step)` (soma_run.erl line 55 — no default key). The run pid
   dies without sending a terminal message to its `session_pid` (the actor), so
   the task sits at `running` forever. `docs/usage.md` line 299 claims the actor
   "validates" the steps list, which isn't true today.

3. **ask/3 with no steps.** A no-steps envelope is valid by design and starts no
   run. `ask/3` (soma_actor.erl line 98) validates it, parks the caller in
   `#data.waiters` (line 113), and starts no run. No terminal event ever fires,
   so the caller blocks until `TimeoutMs` and the actor keeps a stale waiter.

4. **Release docs.** The relx release in `rebar.config` line 28 lists
   `soma_event_store`, `soma_tools`, `soma_runtime`, `sasl`. `docs/release.md`
   line 3 says the tarball bundles "the three apps". Neither mentions
   `soma_actor`, which the README now presents as built.

## Approach

Honor the four locked decisions from the issue. No core-thesis change: the actor
owns tasks, starts known step lists through `soma_run`, takes the terminal run
message as data, and never runs tool logic itself.

1. **Startup — add the dependency.** Add `soma_runtime` to
   `soma_actor.app.src`'s `applications` list. Now
   `application:ensure_all_started(soma_actor)` brings up `soma_run_sup` on its
   own. Update the README quickstart so the documented path matches (drop any
   "start soma_runtime too" instruction). The one-way boundary holds:
   `soma_actor → soma_runtime` is allowed, the runtime still never imports the
   actor.

2. **Malformed steps — monitor the run and validate up front.**
   - (a) In `maybe_start_run`, after `soma_run_sup:start_run/1` returns the run
     pid, the actor calls `erlang:monitor(process, RunPid)`. This mirrors
     `soma_run → soma_tool_call`. A run that dies without a terminal message
     arrives as a `'DOWN'` and is recorded as a terminal `failed` task — data,
     not a stuck `running`. The normal terminal messages
     (`run_completed | run_failed | run_timeout | run_cancelled`) demonitor so a
     still-alive completed run leaves no dangling monitor. This catches any
     silent run death, not only malformed steps.
   - (b) Validate steps up front. A step map missing `id` or `tool` is rejected
     with `{error, Reason}` before any run starts, so a known-bad step list never
     reaches `soma_run`.
   - Both layers matter. Up-front validation is the front door for the malformed
     case the issue names. The monitor is the backstop for any other run death.
     Tests cover each on its own path.
   - `docs/usage.md`'s "validates the steps list" line becomes true and is
     refined to say what is actually checked: each step is a map with `id` and
     `tool`.

3. **ask/3 no-steps — return `{ok, accepted, TaskId}`.** A no-steps envelope is
   valid, so the result is `ok`-flavored. `ask/3` replies immediately with the
   3-tuple `{ok, accepted, TaskId}` and parks no waiter. The distinct shape is
   deliberate: a completed-run `ask` stays `{ok, OutputsMap}`, so `{ok, Result}`
   keeps one meaning and a bare `{ok, TaskId}` never overloads it. Document the
   value in `docs/usage.md`. `send/2` with no steps is unchanged: still
   `{ok, TaskId}`, status `accepted`.

4. **Release — document the exclusion, don't expand the release.** Keep the relx
   release as the execution core. Make `docs/release.md`'s app list match
   `rebar.config` (core apps only — `soma_event_store`, `soma_tools`,
   `soma_runtime`, `sasl`) and state plainly that the release boots the runtime
   core, while `soma_actor` is a layer the embedding application starts and is
   not yet bundled. No new release smoke test here.

The two doc-only criteria (8, 9) and the contract-update criterion (10) are
prose. They don't get a `test_*`; their proof is the file content and the green
gate.

## Acceptance criteria → tests

### Criterion 1 — quickstart path runs to a terminal result after `ensure_all_started(soma_actor)` alone
- Call chain: `application:ensure_all_started(soma_actor)` (now pulls in
  `soma_runtime`, so `soma_run_sup` is up) → `soma_actor_sup:start_actor` →
  `soma_actor:send` / `ask` with a steps envelope → `soma_actor:idle/3` →
  `maybe_start_run` → `soma_run_sup:start_run` → run reaches `run.completed` →
  actor records the task as `completed`
- Test entry: `application:ensure_all_started(soma_actor)` — the test starts only
  the actor app and nothing else, which is the exact contract criterion 1 names.
  It must not call `ensure_all_started(soma_runtime)` the way the existing
  run-integration cases do.
- Test: `actor_only_start_runs_steps_to_terminal` in
  `apps/soma_actor/test/soma_actor_startup_SUITE.erl`

### Criterion 2 — malformed steps don't leave the task at `running`
- Call chain: `soma_actor:send` with a step missing `id` → `soma_actor:idle/3` →
  up-front step validation rejects it (no run started); OR if a run dies
  silently, `soma_run` pid exits → actor's `'DOWN'` handler records `failed`
- Test entry: `soma_actor:send`. The test submits a step map missing `id` and
  asserts the outcome is either `{error, Reason}` up front or a terminal
  `failed` status — never `running`.
- Test: `malformed_steps_rejected_or_failed_not_running` in
  `apps/soma_actor/test/soma_actor_validation_SUITE.erl`

### Criterion 3 — actor stays alive after a malformed-steps envelope
- Call chain: `soma_actor:send` with a malformed-steps envelope →
  `soma_actor:idle/3` → reject or record-failed → actor stays in `idle`
- Test entry: `soma_actor:send`. After submission the test asserts
  `is_process_alive(ActorPid)`.
- Test: `actor_alive_after_malformed_steps` in
  `apps/soma_actor/test/soma_actor_validation_SUITE.erl`

### Criterion 4 — a valid steps envelope after a malformed one still completes
- Call chain: malformed `send` (rejected or failed) → valid `send` on the same
  actor → `maybe_start_run` → `soma_run_sup:start_run` → `run.completed` → task
  `completed`
- Test entry: `soma_actor:send`. The test submits the bad envelope, then a good
  echo-step envelope to the same actor, and asserts the second task reaches
  `completed`.
- Test: `valid_steps_complete_after_malformed` in
  `apps/soma_actor/test/soma_actor_validation_SUITE.erl`

### Criterion 5 — ask/3 with no steps returns `{ok, accepted, TaskId}` instead of blocking
- Call chain: `soma_actor:ask` with a no-steps envelope →
  `soma_actor:idle/3` ({ask, Envelope}) → validate ok → no run started → immediate
  reply `{ok, accepted, TaskId}`, no waiter parked
- Test entry: `soma_actor:ask`. The test passes a generous `TimeoutMs`, calls
  with a no-steps envelope, and asserts the return is `{ok, accepted, TaskId}` —
  arriving well before the timeout.
- Test: `ask_no_steps_returns_ok_accepted` in
  `apps/soma_actor/test/soma_actor_validation_SUITE.erl`

### Criterion 6 — after that ask/3 returns, the actor holds no parked waiter
- Call chain: `soma_actor:ask` (no-steps) → reply `{ok, accepted, TaskId}`,
  waiters untouched → read the actor's `#data.waiters`
- Test entry: `soma_actor:ask`, then a read of the actor's `waiters` map. The
  test uses `sys:get_state/1` on the actor pid to inspect `#data.waiters` and
  asserts the task id is absent. `sys:get_state` is the off-chain read; the
  reason is that `waiters` is private actor state with no public getter, so the
  test reaches it through the standard `sys` introspection rather than a call
  chain.
- Test: `ask_no_steps_parks_no_waiter` in
  `apps/soma_actor/test/soma_actor_validation_SUITE.erl`

### Criterion 7 — send/2 no-steps still returns `{ok, TaskId}`, starts no run, status `accepted`
- Call chain: `soma_actor:send` (no-steps) → `soma_actor:idle/3` ({send, …}) →
  validate ok → `maybe_start_run` starts nothing → reply `{ok, TaskId}` →
  `soma_actor:get_task_status` reads `accepted`
- Test entry: `soma_actor:send`, then `soma_actor:get_task_status`. The test
  asserts the `send` return is `{ok, TaskId}` and the status is `accepted`. (This
  re-pins the existing `no_steps_accepts_and_starts_no_run` behavior; the new
  test keeps it explicit in this issue's suite so decision 3's "send unchanged"
  has a proof here.)
- Test: `send_no_steps_accepted_no_run` in
  `apps/soma_actor/test/soma_actor_validation_SUITE.erl`

### Criterion 8 — `docs/release.md` app list matches `rebar.config`
- Call chain: none (direct source-file read)
- Test entry: none. The check is that the app set named in `docs/release.md`
  equals the relx release list in `rebar.config` (`soma_event_store`,
  `soma_tools`, `soma_runtime`, `sasl`), and that `release.md` states `soma_actor`
  is not yet bundled. Verified by reading both files, not by a `test_*`.
- Test: none — doc reconciliation, confirmed by review and the green gate.

### Criterion 9 — `docs/usage.md` wording matches actual validation
- Call chain: none (direct source-file read)
- Test entry: none. After decision 2b lands real step validation, the
  `docs/usage.md` "validates the steps list" line is refined to name what is
  checked (each step is a map with `id` and `tool`). Verified by reading the doc
  against the implemented validation.
- Test: none — doc reconciliation, confirmed by review.

### Criterion 10 — `v0.4-test-contract.md` lists the new edge-case proofs
- Call chain: none (direct source-file read)
- Test entry: none. `docs/contracts/v0.4-test-contract.md` gains an edge-case
  section mapping each new proof (criteria 1–7) to its suite and case. Verified
  by reading the contract against the suites this issue adds.
- Test: none — contract documentation, confirmed by review.

### Criterion 11 — `rebar3 eunit && rebar3 ct` green at HEAD
- Call chain: none (compile-time + full-suite gate)
- Test entry: none. The merge gate runs both suites; this criterion is the gate
  passing with the new suites included.
- Test: none — the whole gate is the proof.

## Risks & trade-offs

- **Two layers for one symptom (decision 2).** Up-front validation and the run
  monitor both guard the malformed-steps case, so the validation path and the
  monitor path overlap for that input. That's on purpose — the monitor is the
  backstop for run deaths the validator can't foresee — but it means criterion 2
  can pass through either path, and the test accepts both outcomes
  (`{error, Reason}` or terminal `failed`). The dev should make the validation
  path the one a missing-`id` step actually takes, and add a separate proof that
  the monitor records `failed` for a run that dies after passing validation, so
  the backstop isn't left untested. That second proof is not a listed criterion;
  it's covered under criterion 2's "or reaches terminal failed" wording.

- **New `{ok, accepted, TaskId}` shape (decision 3).** Any caller that pattern-
  matched `ask/3` as only `{ok, _} | {error, _} | timeout` now sees a third
  ok-flavored shape for no-steps. Inside this repo `ask/3` callers all pass steps,
  so nothing breaks today, but the shape is public surface and is documented in
  `docs/usage.md` for that reason.

- **Release still excludes the actor (decision 4).** The packaged release does
  not boot `soma_actor`, so the "v0.4 is built" story and the "release bundles
  the core" story stay separate. We document the gap rather than hide it.
  Bundling the actor with its own boot smoke test is a clean follow-up issue, out
  of scope here.

- **The startup test must not borrow the runtime (criterion 1).** The new
  startup suite has to call `ensure_all_started(soma_actor)` and nothing else. If
  its `init_per_testcase` copies the existing pattern and adds
  `ensure_all_started(soma_runtime)`, the test would pass even with the app.src
  fix reverted, so it would prove nothing. The dev must keep the startup case's
  setup minimal.
