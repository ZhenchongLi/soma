# [cc] v0.2: register built-in Erlang tools through manifests

## Current state

The v0.2 manifest machinery is built but disconnected from the five built-in tools.

`soma_tool_manifest:normalize/1` takes a full manifest map and validates it. For an
`erlang_module` tool it requires `name`, `effect`, `idempotent`, `timeout_ms`,
`adapter`, and `module`, then returns a canonical map with only those keys. Nothing
in production calls it yet. Its only callers are the unit tests in
`apps/soma_tools/test/soma_tool_manifest_tests.erl`, which feed it hand-written
fixtures.

The five built-ins (`echo`, `sleep`, `fail`, `file_read`, `file_write`) each have a
`describe/0` that returns four keys: `name`, `effect`, `idempotent`, `timeout_ms`.
No built-in declares an `adapter` or a backing `module`. So a built-in's `describe/0`
output is not a manifest, and you cannot hand it to `normalize/1` without filling in
two missing keys.

The running registry seeds itself from a literal in `soma_tool_registry.erl`:

```erlang
-define(SEED, #{echo => #{adapter => erlang_module, module => soma_tool_echo},
                ...}).
```

These five descriptors are typed by hand. They never pass through `normalize/1`, so
the registry seed and the manifest contract have no link. If a built-in's metadata
changed, the seed would not know, and the seed could hold a shape `normalize/1`
would reject without anyone noticing.

What this leaves unproven: manifests work for built-in Erlang tools, not just for the
external `cli` tools that motivated them. The built-ins should be the first real
manifests in the tree.

## Approach

Give each built-in a `manifest/0` that returns its full manifest map, then build the
registry seed by running each through `normalize/1`.

Each built-in module gains a `manifest/0` export. It returns `describe/0` merged with
the two `erlang_module` keys:

```erlang
manifest() ->
    (describe())#{adapter => erlang_module, module => ?MODULE}.
```

Writing it as `describe()` merged with the adapter pair, rather than a second literal
map, keeps the four metadata values in one place. `describe/0` stays the single
source for `name`, `effect`, `idempotent`, `timeout_ms`. `manifest/0` adds only what
the manifest contract needs on top. This is why criterion 2 (manifest metadata equals
`describe/0` metadata) holds by construction, not by a copy that could drift.

`manifest/0` is a plain export, not a new callback on the `soma_tool` behaviour.
The issue puts changing the behaviour contract out of scope, so adding a `-callback`
is off the table. A bare export gives every built-in the function the registry needs
without touching `soma_tool.erl`.

The registry seed is built from those manifests at module load. `soma_tool_registry`
replaces the literal `?SEED` with a function that lists the five backing modules,
calls `Module:manifest()` on each, runs the result through
`soma_tool_manifest:normalize/1`, and stores the normalized manifest keyed by its
`name`. A manifest that fails `normalize/1` crashes the seed build, so a malformed
built-in manifest stops the registry from starting rather than seeding a bad
descriptor.

The seeded descriptor widens from `#{adapter, module}` to the full normalized
manifest `#{name, effect, idempotent, timeout_ms, adapter, module}`. The narrow shape
is a strict subset of the wide one, so this is safe for the existing readers:

- `resolve/1` reads `module` out of the descriptor. The normalized manifest still
  carries `module`, so `resolve/1` is unchanged.
- `resolve_descriptor/1` returns the stored descriptor as-is. Its callers in
  `soma_run_happy_path_SUITE` assert on `adapter` and `module`, both still present.

Storing the full manifest is the choice that makes the seed self-describing: the
descriptor a name resolves to now carries the same metadata the tool declares, with no
second copy. The alternative, projecting back down to `#{adapter, module}` after
normalizing, would throw away the metadata we just validated for no gain.

The `descriptor()` type in `soma_tool_registry` widens to match the normalized
manifest shape. Tool behavior, event output, and run execution are untouched: this
issue only changes where the registry's descriptors come from.

## Acceptance criteria → tests

### Criterion 1 — each built-in's manifest normalizes to `{ok, _}`
- Call chain: `Module:manifest/0` → `soma_tool_manifest:normalize/1`
- Test entry: `soma_tool_manifest:normalize/1`, fed the live `Module:manifest()` for
  each of the five built-ins. The manifest is read from the production `manifest/0`,
  not a fixture, which is what "from the production source" requires.
- Test: `test_builtin_manifests_normalize` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 2 — normalized manifest metadata equals `describe/0` metadata
- Call chain: `Module:describe/0` and `Module:manifest/0` →
  `soma_tool_manifest:normalize/1`
- Test entry: for each built-in, normalize `Module:manifest()` and compare its
  `name`, `effect`, `idempotent`, `timeout_ms` against the same four keys read from
  `Module:describe()`.
- Test: `test_builtin_manifest_metadata_matches_describe` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 3 — each built-in manifest names `erlang_module` and points `module` at its backing module
- Call chain: `Module:manifest/0` → `soma_tool_manifest:normalize/1`
- Test entry: for each built-in, normalize `Module:manifest()` and assert `adapter`
  is `erlang_module` and `module` is the backing module (`soma_tool_echo` for `echo`,
  and so on).
- Test: `test_builtin_manifest_names_erlang_module_adapter` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 4 — the running registry seeds each built-in from its normalized manifest
- Call chain: `application:ensure_all_started(soma_runtime)` → `soma_sup` →
  `soma_tool_registry:start_link` → `init/1` seeds from the built-in manifests →
  test calls `soma_tool_registry:resolve_descriptor/1`
- Test entry: `soma_tool_registry:resolve_descriptor/1` against the booted runtime.
  The test enters at the running registry, not the pure seed function, because the
  criterion is about the descriptor the live registry hands back. For each built-in
  name, the descriptor returned must equal `normalize(Module:manifest())`'s `{ok, M}`
  payload. Equality against the freshly normalized manifest is what proves the seed
  was built from the manifest rather than a literal.
- Test: `test_registry_seeds_descriptors_from_manifests` in
  `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 5 — `rebar3 eunit` and `rebar3 ct` green at HEAD
- Call chain: none (build-gate check)
- Test entry: the relay merge gate runs both. The other four criteria's tests run
  inside this gate, so this criterion is met when they pass and nothing else regresses.
- Test: the full `rebar3 eunit` and `rebar3 ct` runs

## Risks & trade-offs

Widening the seeded descriptor to the full normalized manifest changes what
`resolve_descriptor/1` returns. Any future code that pattern-matches a descriptor as
exactly `#{adapter, module}` with no other keys would break. Today no such matcher
exists: `resolve/1` reads `module`, and the SUITE reads `adapter` and `module`, both
by key, neither by exact-map shape. The widening is safe now but is a coupling point
to keep in mind.

`manifest/0` repeats the `adapter => erlang_module` and `module => ?MODULE` pair in
five modules. That is five near-identical functions instead of one helper that derives
the manifest from `describe/0`. The repetition is small and keeps each tool's manifest
readable in the tool's own file, which is the trade I am taking over a central
generator that would hide the per-tool shape. A follow-up could fold them into one
helper if the pair ever grows.
