# [cc] v0.4: app skeleton — apps/soma_actor + soma_actor_sup boots

## Current state

The umbrella has four apps today: `soma_event_store`, `soma_tools`,
`soma_runtime`, `soma_lfe`. The `soma_actor` agent-entity layer the v0.4 epic
(#52) plans does not exist yet. The v0.4 test contract (#53,
`docs/contracts/v0.4-test-contract.md`) is merged and names the supervisor
`soma_actor_sup` and the suite `soma_actor_SUITE`, but no code backs those names.

There is no app boundary to fill in. Slice 3 wants to add the `soma_actor`
gen_statem under a root supervisor, but it has nowhere to go: there's no
`apps/soma_actor`, no application callback, no root supervisor. This slice
builds that empty shell so the later slices have a real, buildable boundary to
extend.

This is scaffolding only. No `soma_actor` worker, no envelope handling, no run
integration, no events. Those are slices 3 and later.

## Approach

Add a new OTP application `apps/soma_actor` that mirrors the `soma_runtime`
pattern exactly:

- `soma_actor_app` is the application callback (`application` behaviour). Its
  `start/2` calls `soma_actor_sup:start_link()`, same shape as `soma_app`.
- `soma_actor_sup` is the root supervisor, registered as `{local, soma_actor_sup}`.
  It uses `simple_one_for_one`, mirroring `soma_run_sup` rather than the
  `one_for_one` `soma_sup`. The contract (decision 4) says this supervisor will
  supervise actor instances on demand, so `simple_one_for_one` is the right
  strategy from the start.
- The single child spec forward-references `soma_actor` as the dynamic worker's
  start module: `start => {soma_actor, start_link, []}`. That module does not
  exist yet — it lands in slice 3. A `simple_one_for_one` child spec is only
  resolved when `start_child` runs, and this slice never calls `start_child`, so
  the named-but-absent module compiles clean. The open question in the issue
  flags `warnings_as_errors`; `rebar.config` does set
  `{erl_opts, [debug_info, warnings_as_errors]}`, but a child-spec map is plain
  data, not a call site, so the compiler has no reference to warn on. If the
  build disagrees, the fallback is to drop the child spec to `[]` for this slice
  and add it back in slice 3 — but the expectation is it compiles as written.
- `soma_actor.app.src` declares `{mod, {soma_actor_app, []}}` and
  `{registered, [soma_actor_sup]}`, with `{applications, [kernel, stdlib]}`.
  No dependency on `soma_runtime` — the dependency is one-way and `soma_actor`
  is the importer, not the imported (same boundary `soma_lfe` keeps). Since this
  slice has no run integration yet, it does not even need `soma_runtime` in its
  app deps; that wiring rides slice 5 when the actor actually starts runs.

The reverse direction stays clean: `soma_runtime.app.src` keeps its current
`applications` list with no `soma_actor` entry, and no module under
`apps/soma_runtime` mentions `soma_actor`. The runtime must not know the actor
layer exists.

No `soma_llm_call_sup` anywhere. The contract (decision 4) says the v0.5
`soma_llm_call` is owner-spawned by `soma_actor`, the same way `soma_run` spawns
`soma_tool_call`, so there is deliberately no separate supervisor for it. This
slice must not introduce one by accident.

The release/shell `relx` wiring in `rebar.config` is out of scope per the issue —
booting the app in a test does not need it.

## Acceptance criteria → tests

The boot proof is one EUnit module, `soma_actor_app_tests`, in
`apps/soma_actor/test/`. EUnit fits because the assertions are about a single
boot of one app and one supervisor, with no multi-process choreography. Each
test starts the app with `application:ensure_all_started(soma_actor)` and stops
it after, mirroring the `init_per_testcase` / `end_per_testcase` pattern in
`soma_run_happy_path_SUITE`.

### Criterion 1 — app.src declares the mod callback
- Call chain: none (direct source-file read)
- Test entry: a source-file assertion, off any call chain, because this checks a
  static `.app.src` declaration, not runtime behavior
- Test: `test_app_src_declares_mod` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 2 — rebar3 compile builds soma_actor in the umbrella
- Call chain: none (compile-time assertion)
- Test entry: the `rebar3 compile` step of the merge gate, off any test call
  chain, because a clean build is what proves it
- Test: covered by the merge gate's `rebar3 compile`; no per-criterion test
  function. The boot tests below only run once the app compiles.

### Criterion 3 — ensure_all_started returns {ok, _}
- Call chain: `application:ensure_all_started(soma_actor)` → `soma_actor_app:start/2`
  → `soma_actor_sup:start_link/0`
- Test entry: `application:ensure_all_started(soma_actor)` (the real boot entry,
  no layer bypassed)
- Test: `test_ensure_all_started_ok` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 4 — soma_actor_sup is registered and alive after boot
- Call chain: `application:ensure_all_started(soma_actor)` → `soma_actor_app:start/2`
  → `soma_actor_sup:start_link/0` → `whereis(soma_actor_sup)`
- Test entry: `application:ensure_all_started(soma_actor)`, then `whereis` on the
  registered name (no layer bypassed)
- Test: `test_sup_registered_and_alive` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 5 — soma_actor_sup uses simple_one_for_one
- Call chain: `application:ensure_all_started(soma_actor)` → boot →
  `supervisor:count_children(soma_actor_sup)` / `sys:get_state`
- Test entry: `application:ensure_all_started(soma_actor)`, then read the live
  supervisor's strategy through `supervisor:count_children/1` (its result shape
  reflects the strategy) — this enters at the booted supervisor, no layer skipped
- Test: `test_sup_strategy_simple_one_for_one` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 6 — soma_actor_sup has zero children after boot
- Call chain: `application:ensure_all_started(soma_actor)` → boot →
  `supervisor:which_children(soma_actor_sup)`
- Test entry: `application:ensure_all_started(soma_actor)`, then
  `supervisor:which_children/1` on the live supervisor (no layer bypassed)
- Test: `test_sup_zero_children_after_boot` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 7 — soma_runtime.app.src does not list soma_actor
- Call chain: none (direct source-file read)
- Test entry: a source-file assertion, off any call chain, because this checks a
  static `applications` list in `soma_runtime.app.src`
- Test: `test_runtime_app_src_excludes_soma_actor` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 8 — no module under apps/soma_runtime references soma_actor
- Call chain: none (direct source-file read)
- Test entry: a source-tree scan, off any call chain, because this is a grep over
  `apps/soma_runtime/src` source files, not runtime behavior
- Test: `test_no_runtime_module_references_soma_actor` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 9 — no soma_llm_call_sup anywhere
- Call chain: none (direct source-file read)
- Test entry: a source-tree scan, off any call chain, because this checks the
  absence of a module file and a registered name across the tree
- Test: `test_no_soma_llm_call_sup_in_tree` in `apps/soma_actor/test/soma_actor_app_tests.erl`

### Criterion 10 — a test starts the app and asserts soma_actor_sup is alive
- Call chain: `application:ensure_all_started(soma_actor)` → `soma_actor_app:start/2`
  → `soma_actor_sup:start_link/0` → `is_process_alive(whereis(soma_actor_sup))`
- Test entry: `application:ensure_all_started(soma_actor)` (the real boot entry)
- Test: satisfied by `test_sup_registered_and_alive` (criterion 4); the
  is-alive-after-boot assertion is the same proof

### Criterion 11 — rebar3 eunit && rebar3 ct is green
- Call chain: none (compile-time / suite-run assertion)
- Test entry: the merge gate, off any single test call chain
- Test: the merge gate runs `rebar3 eunit && rebar3 ct`; no per-criterion test
  function. The new EUnit module must run green and must not break the existing
  CT suites.

## Risks & trade-offs

The forward-referenced `soma_actor` module is the one real risk. If
`warnings_as_errors` does trip on the absent module (it should not, since a
child-spec map is data), the slice falls back to an empty child list `[]` and
slice 3 adds the spec when the worker exists. That fallback is a worse honesty
story — the supervisor would not name its dynamic child until slice 3 — so the
named-module form is preferred and the fallback is only if the build forces it.

Criteria 8 and 9 are absence checks. A source-tree grep test proves absence
today but cannot stop a later slice from adding a reference; it only catches a
regression if the test stays in the suite. That is acceptable for scaffolding —
the test documents the boundary and fails loudly if a future change crosses it.

Putting the boundary-shape tests (criteria 7, 8, 9) in `soma_actor`'s own test
dir rather than `soma_runtime`'s is a small oddity: a test about
`soma_runtime.app.src` lives in `soma_actor`. The alternative spreads this
slice's proof across two apps' test dirs. Keeping all eleven criteria in one
module is the simpler read, so the cross-app assertions live with the rest.
