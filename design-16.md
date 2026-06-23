# [cc] v0.2: upgrade the tool registry to resolve descriptors, not only modules

## Current state

`soma_tool_registry` maps a tool name straight to an Erlang module. The seed map
holds `echo => soma_tool_echo` and the four other built-ins. `register/3` stores
`Name => Module`. `lookup/2` returns `{ok, Module}` or `{error, not_found}`.
`resolve/1` calls into the running `gen_server` and hands back whatever `lookup/2`
returns, so it too returns `{ok, Module}`.

`soma_run` resolves a step's tool at `soma_run.erl:59` with

```erlang
{ok, Module} = soma_tool_registry:resolve(ToolName),
```

then passes that bare module to `soma_tool_call`, which calls `Module:invoke/2`.

Two problems for v0.2:

The registry only knows how to name an in-BEAM module. The manifest contract in
`docs/tool-manifest.md` already fixed a two-adapter vocabulary (`erlang_module`
and `cli`), but the registry has no place to record which adapter runs a tool. A
later CLI adapter has nowhere to plug in.

The resolve site in `soma_run` is a hard pattern match. When a step names a tool
that was never registered, `resolve/1` returns `{error, not_found}`, the
`{ok, Module} = ...` match fails, and the `soma_run` process crashes with a
`badmatch`. A run that references a missing tool should end as a `failed` run with
an error payload, the same terminal state an `{error, _}` tool return reaches
today. It should not take the run process down on a raw match failure.

## Approach

Give the registry a descriptor: a map that records the adapter type and, for an
`erlang_module` tool, the backing module. The descriptor reuses the `adapter`
field from the manifest contract. For the five built-ins it is

```erlang
#{adapter => erlang_module, module => soma_tool_echo}
```

The seed map changes from `Name => Module` to `Name => Descriptor`. `register/3`
takes a descriptor in the third argument and stores it. `lookup/2` returns the
descriptor that was stored, `{ok, Descriptor}`.

The descriptor shape lines up with the `erlang_module` branch of
`soma_tool_manifest:normalize/1`, which already returns a map carrying
`adapter => erlang_module` and `module => Module` alongside the four metadata
keys. The registry descriptor is a subset of that normalized shape: it must carry
`adapter` and `module`, and a normalized manifest map satisfies that without
change. That keeps #17 able to seed the registry straight from normalized
manifests. This issue does not read manifests from disk and does not seed from
`normalize/1`; it only fixes the descriptor so the shapes are compatible.

### The resolve API decision

There are two production-adjacent ways to expose the descriptor.

The CT happy-path suite pins the current `resolve/1` contract. Its
`test_registry_seeded_with_v01_tools` asserts `{ok, soma_tool_echo} =
soma_tool_registry:resolve(echo)` and the same for the other four names — the
bare-module shape. Criterion 6 requires that suite to pass unchanged. So
`resolve/1` cannot start returning a descriptor without breaking a test the issue
says must stay green.

The design therefore adds a separate `resolve_descriptor/1` that returns
`{ok, Descriptor} | {error, not_found}`, and leaves `resolve/1` returning the
bare module. `soma_run` switches to `resolve_descriptor/1` and reads the module
out of the descriptor. `resolve/1` keeps its old shape purely so the pinned CT
test passes unchanged; it is no longer on the production run path.

Internally `resolve/1` keeps returning the bare module by reading the `module`
field out of the looked-up descriptor before replying, so the seed map only stores
descriptors and there is one source of truth.

The alternative — change `resolve/1` in place — is simpler in the abstract but
loses on criterion 6: it forces an edit to the protected CT suite. The cost of
the chosen path is one extra exported function and a `resolve/1` that survives
only to feed an old test; #17 or a later cleanup can retire it once nothing pins
the bare-module shape.

### The missing-tool path

`soma_run` stops matching `{ok, Module}` blind. It calls `resolve_descriptor/1`
and branches:

- `{ok, #{module := Module}}` — proceed exactly as today: start the worker, emit
  `tool.started`, wait in `waiting_tool`.
- `{error, not_found}` — record the failure trail and move to `failed`, reusing
  the existing `fail_run/5` path so the unregistered-tool run lands in the same
  terminal state and emits the same `tool.failed`/`step.failed`/`run.failed`
  events as any other failure. The reason carries the unregistered tool name.

The failure here happens before any worker is spawned, so there is no
`tool_call_pid` and no worker to kill. `fail_run/5` already takes the
`tool_call_id` and a worker pid argument; the missing-tool call passes the
freshly minted `tool_call_id` and `undefined` for the worker pid. The event trail
matches the existing shape because `fail_run/5` is unchanged.

The EUnit `soma_tool_registry_tests` module is a unit test, not one of the two CT
suites criterion 6 protects. It asserts the old `register/3` and `lookup/2`
bare-module shapes, so it must change to assert the descriptor shape that
criterion 2 requires. That change is in scope: criterion 2 is a contract change to
`lookup/2`, and the unit test that pins the old contract moves with it.

## Acceptance criteria → tests

### Criterion 1 — a descriptor names its adapter and backing module
- Call chain: none (direct unit call to the pure map API). The descriptor shape
  is asserted by registering one and reading it back.
- Test entry: `soma_tool_registry:register/3` then `lookup/2`, the pure map
  functions, called directly. No process or run layer is involved because the
  descriptor shape is a property of the pure API.
- Test: `test_register_lookup_returns_descriptor` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl`

### Criterion 2 — `lookup/2` returns the descriptor that was registered
- Call chain: none (direct unit call to the pure map API).
- Test entry: `soma_tool_registry:lookup/2`, called directly on a map built by
  `register/3`. The test asserts the value returned is the exact descriptor
  passed to `register/3`, not a bare module atom.
- Test: `test_register_lookup_returns_descriptor` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl`

### Criterion 3 — five v0.1 names resolve to `erlang_module` descriptors
- Call chain: test → `soma_tool_registry:resolve_descriptor/1` →
  `gen_server:call` → `handle_call({resolve_descriptor, Name}, ...)` →
  `lookup/2` against the seeded registry map.
- Test entry: `soma_tool_registry:resolve_descriptor/1` against the running
  registry started under `soma_sup`. No layer bypassed: the test goes through the
  same `gen_server` the run path uses.
- Test: `test_registry_resolves_erlang_module_descriptors` in
  `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 4 — `soma_run` reads the module from the descriptor, demo still completes
- Call chain: `soma_agent_session:start_run` → `soma_run` started under
  `soma_run_sup` → `executing/3` → `soma_tool_registry:resolve_descriptor/1` →
  read `module` from the descriptor → `soma_tool_call:start` → `Module:invoke/2`,
  run across the `file_read → echo → file_write` step list to `completed`.
- Test entry: `soma_agent_session:start_run`, the real run entry point. No layer
  bypassed; the test reads the trail from the event store and confirms
  `run.completed`.
- Test: `test_demo_file_read_echo_file_write` in
  `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl` (existing, must stay
  green; it exercises the descriptor read path after the migration)

### Criterion 5 — an unregistered tool ends the run in `failed`, not a crash
- Call chain: `soma_agent_session:start_run` with a step naming a tool that was
  never registered → `soma_run` `executing/3` →
  `soma_tool_registry:resolve_descriptor/1` returns `{error, not_found}` →
  `fail_run/5` → `failed` state, with `run.failed` recorded.
- Test entry: `soma_agent_session:start_run`, the real run entry point. The test
  asserts the run reaches `failed` with an error payload and that the run process
  did not crash on a badmatch. No layer bypassed.
- Test: `test_unregistered_tool_reaches_failed_not_crash` in
  `apps/soma_runtime/test/soma_run_failure_SUITE.erl`

### Criterion 6 — existing happy-path and failure CT suites pass unchanged
- Call chain: none (the criterion is the existing two CT suites running green
  after the migration).
- Test entry: the existing `soma_run_happy_path_SUITE` and
  `soma_run_failure_SUITE`, run as-is. `resolve/1` keeps its bare-module shape so
  `test_registry_seeded_with_v01_tools` passes without edit; `soma_run`'s switch
  to `resolve_descriptor/1` keeps the demo and every failure case behaving the
  same.
- Test: the full `soma_run_happy_path_SUITE` and `soma_run_failure_SUITE` in
  `apps/soma_runtime/test/`, unchanged except for the two new cases added under
  criteria 3 and 5

## Risks & trade-offs

Keeping `resolve/1` alive next to `resolve_descriptor/1` leaves a second resolve
function whose only job is to satisfy an old CT assertion. That is dead weight on
the production path the moment `soma_run` switches over. The reason to accept it is
criterion 6: changing `resolve/1` in place would force an edit to a CT suite the
issue says must pass unchanged. The clean-up — fold `resolve/1` away once nothing
pins the bare-module shape — belongs to #17 or a later issue, not here.

The descriptor is a registry-local shape, not the full normalized manifest. It
carries `adapter` and `module` and nothing more for the built-ins. A normalized
manifest map is a superset, so #17 can register normalized manifests directly, but
this issue does not prove that path — it only keeps the shapes from diverging. If
#17 needs the registry to carry the four metadata keys too, that is an additive
change to the descriptor, not a rework.
