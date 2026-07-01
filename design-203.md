# [cc] Manifest v2: model-facing description/params and registry catalog

## Current state

A tool manifest carries only the runtime-facing half. `soma_tool_manifest:normalize/1`
(`apps/soma_tools/src/soma_tool_manifest.erl`) checks `name` / `effect` /
`idempotent` / `timeout_ms` / `adapter` plus the adapter fields, then
`normalize_complete/1` rebuilds the descriptor from an exact key list — stray
keys are dropped, so a `description` in a manifest today would silently vanish.

`soma_tool_registry` (`apps/soma_tools/src/soma_tool_registry.erl`) stores
`name => descriptor` and exposes `resolve/1` / `resolve_descriptor/1`. Both hand
back runtime internals (`module`, `executable`, `argv`). There is no read path
that gives a planning model just "what tools exist and how to call them"
without also leaking those internals.

The five built-in modules (`soma_tool_echo`, `soma_tool_sleep`, `soma_tool_fail`,
`soma_tool_file_read`, `soma_tool_file_write`) each build `manifest/0` as
`(describe())#{adapter => erlang_module, module => ?MODULE}`. None has a prose
description, so even with a catalog they would be invisible to a planner.

`docs/tool-abstraction.md` §3 specifies the target shape; this issue is its T.1
slice.

## Approach

Three additive changes, all inside `apps/soma_tools`.

**1. `normalize/1` learns the optional model-facing half.** After the existing
adapter-field checks, a new validation step runs before `normalize_complete/1`:

- `description`, when present, must be a binary → else
  `{error, {invalid_description, Value}}`.
- `params`, when present, must be a list of param specs. Each spec must be a
  map with `name` (binary — never an atom, these arrive from external
  manifests), `type` (one of `string | integer | boolean`), `required`
  (boolean), and optionally `doc` (binary). Any violation — non-list `params`,
  non-map spec, missing key, unknown `type`, non-binary `doc` — is
  `{error, {invalid_params, Value}}` carrying the offending value.

`normalize_complete/1` then merges `description` and `params` into the rebuilt
descriptor only when the input carried them (`maps:with([description, params],
Manifest)` after validation, or an equivalent conditional merge). Each param
spec is itself rebuilt to exactly `name` / `type` / `required` (+ `doc` when
present), so stray keys inside a param spec are dropped the same way stray
top-level keys already are — this keeps `normalize/1` idempotent, which the
existing `test_normalize_is_idempotent` locks in. A manifest without the new
fields takes the exact code path it takes today and produces a map with no new
keys.

**2. `soma_tool_registry:catalog/0`.** Following the module's existing split, a
pure function over the registry map (`catalog/1`) plus a `gen_server` call
wrapper (`catalog/0`). It folds over the stored descriptors, keeps only those
with a `description` key, and builds each entry as exactly
`#{name => Name, description => Description, params => Params}` with `params`
defaulting to `[]` when the descriptor has none. Nothing else is copied — the
entry is constructed from those three values, not filtered down from the
descriptor, so `module` / `executable` / `argv` / `effect` / `idempotent` /
`timeout_ms` cannot leak by accident. Entries are sorted by name so the output
is deterministic. The `descriptor()` type gains the two optional fields.

**3. Built-in descriptions.** Each of the five built-ins adds a `description`
binary (and `params` where the tool takes structured input worth declaring —
Dev's call per tool; `description` alone satisfies the criterion) into its
`manifest/0` map, not into `describe/0`. `describe/0` stays the runtime-facing
`soma_tool:spec()`, and the existing
`test_builtin_manifest_metadata_matches_describe` keeps passing untouched.

`docs/tool-manifest.md` gets a short section documenting the two optional
fields, since it is the normative manifest contract (`soma_tool_manifest_doc_tests`
only asserts presence of existing content, so this is additive there too).

New behavioural guarantees go into a v2 section of the relevant
`docs/contracts/` file per repo convention.

## Acceptance criteria → tests

### Criterion 1 — normalize preserves valid `description` and `params`
- Call chain: `soma_tool_registry:register_tool/1` (or `seed/0`) →
  `soma_tool_manifest:normalize/1` → `normalize_complete/1`
- Test entry: `soma_tool_manifest:normalize/1` (pure validation edge; the
  registry layer is proven separately by criteria 4–7)
- Code boundary: `apps/soma_tools/src/soma_tool_manifest.erl`
- Responsibility owner: `soma_tool_manifest` owns manifest validation and the
  canonical descriptor shape
- Test: `test_normalize_accepts_description_and_params` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 2 — invalid model-facing fields fail closed with named errors
- Call chain: `soma_tool_registry:register_tool/1` →
  `soma_tool_manifest:normalize/1` → model-facing validation step
- Test entry: `soma_tool_manifest:normalize/1` (same reason as criterion 1)
- Code boundary: `apps/soma_tools/src/soma_tool_manifest.erl`
- Responsibility owner: `soma_tool_manifest` owns fail-closed edge validation
- Test: `test_normalize_rejects_invalid_model_facing_fields` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl` (case list: non-binary
  `description` → `{error, {invalid_description, _}}`; non-list `params`,
  non-map spec, each missing key, unknown `type`, non-binary `doc` →
  `{error, {invalid_params, _}}`)

### Criterion 3 — a v1 manifest normalizes byte-for-byte as today
- Call chain: `soma_tool_registry:register_tool/1` →
  `soma_tool_manifest:normalize/1` → `normalize_complete/1`
- Test entry: `soma_tool_manifest:normalize/1`
- Code boundary: `apps/soma_tools/src/soma_tool_manifest.erl`
- Responsibility owner: `soma_tool_manifest` owns backward compatibility of the
  descriptor shape
- Test: `test_normalize_without_model_facing_fields_adds_no_keys` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl` (exact-map equality for
  both adapters, plus an assertion that neither `description` nor `params` is a
  key). The "existing tests pass unchanged" half is the unmodified rest of
  `soma_tool_manifest_tests` and `soma_tool_registry_tests` staying green.

### Criterion 4 — catalog entries are exactly the model-facing half
- Call chain: planner/prompt builder (future) → `soma_tool_registry:catalog/0`
  → `gen_server` call → pure catalog fold over the registry map
- Test entry: `soma_tool_registry:catalog/0` on a registry started with
  `start_link/0` (no layer bypassed; same fixture style as the existing
  `register_tool_rejects_missing_field_name_unresolvable_test_`)
- Code boundary: `apps/soma_tools/src/soma_tool_registry.erl`
- Responsibility owner: `soma_tool_registry` owns what the catalog exposes and
  what it withholds
- Test: `test_catalog_entry_is_exactly_name_description_params` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl` (register a manifest with
  `description` + `params` and one with `description` only; assert each entry's
  key set is exactly `[name, description, params]`, `params` defaults to `[]`,
  and no entry contains `module` / `executable` / `argv` / `effect` /
  `idempotent` / `timeout_ms`)

### Criterion 5 — a description-less tool is absent from the catalog
- Call chain: `soma_tool_registry:register_tool/1` (v1 manifest) →
  `soma_tool_registry:catalog/0`
- Test entry: `soma_tool_registry:register_tool/1` then `catalog/0` on a
  started registry
- Code boundary: `apps/soma_tools/src/soma_tool_registry.erl`
- Responsibility owner: `soma_tool_registry` owns the "no description = not
  offered to planners" rule
- Test: `test_tool_without_description_absent_from_catalog` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl` (register a v1 manifest,
  assert its name resolves via `resolve_descriptor/1` but appears in no catalog
  entry)

### Criterion 6 — register_tool with model-facing fields shows up in the catalog
- Call chain: `soma_tool_registry:register_tool/1` → `normalize/1` → registry
  map → `catalog/0`
- Test entry: `soma_tool_registry:register_tool/1` then `catalog/0` on a
  started registry (no layer bypassed)
- Code boundary: `apps/soma_tools/src/soma_tool_registry.erl` (and the
  `normalize/1` path it reuses)
- Responsibility owner: `soma_tool_registry` owns registration flowing through
  to the catalog
- Test: `test_register_tool_with_model_facing_fields_appears_in_catalog` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl` (register, then assert
  the catalog entry carries the exact `description` and `params` registered)

### Criterion 7 — the five built-ins declare descriptions and seed the catalog
- Call chain: `soma_sup` boot → `soma_tool_registry:start_link/0` → `init/1` →
  `seed/0` → each `Module:manifest()` → `normalize/1` → `catalog/0`
- Test entry: `soma_tool_registry:start_link/0` then `catalog/0` (start_link
  runs the same `init`/`seed` the supervisor runs; only the supervisor wrapper
  is skipped, and it adds no behavior)
- Code boundary: `manifest/0` in `apps/soma_tools/src/soma_tool_echo.erl`,
  `soma_tool_sleep.erl`, `soma_tool_fail.erl`, `soma_tool_file_read.erl`,
  `soma_tool_file_write.erl`
- Responsibility owner: each built-in tool module owns its own model-facing
  description; the registry only reflects it
- Test: `test_seeded_catalog_lists_all_five_builtins` in
  `apps/soma_tools/test/soma_tool_registry_tests.erl` (fresh `start_link/0`,
  assert the catalog names are exactly `echo`, `sleep`, `fail`, `file_read`,
  `file_write` and every entry has a non-empty binary `description`)

## Risks & trade-offs

- **Dropping stray keys inside param specs is stricter than "preserve".** The
  criterion says preserve `params`; rebuilding each spec to the declared keys
  preserves the declared content while keeping one canonical shape and
  normalize idempotency. If Dev instead passes specs through verbatim, the
  idempotency test still passes but two normalizations of "the same" manifest
  can differ by junk keys. The rebuild is the safer default.
- **`{invalid_params, Value}` is one umbrella for six failure shapes.** A
  caller can't tell "missing `required`" from "bad `type`" without inspecting
  the payload. That matches the issue's decision (fail closed, one named error
  per field) and the module's existing granularity; finer diagnostics can come
  later without breaking the tuple shape.
- **Registry tests share the `{local, soma_tool_registry}` name.** Every
  catalog test needs the started `gen_server`; the suite must keep the existing
  setup/teardown fixture pattern (start, test, `gen_server:stop`) or tests will
  collide on the registered name. Grouping the new cases under one `{setup, …}`
  generator per test (as the existing one does) avoids ordering flakes.
- **Descriptions in `manifest/0`, not `describe/0`.** This leaves a tool's
  prose next to its adapter wiring rather than its runtime spec. It's the
  smaller change (the `describe/0` ↔ manifest drift test stays untouched) and
  matches the doc's framing of description as manifest-level, but it means a
  future consumer of `describe/0` alone won't see descriptions.
