### Claude

## Verdict
approve

## Real issues
None.

## Questions
None.

## Nits
- The five `manifest/0` bodies are identical: `(describe())#{adapter => erlang_module, module => ?MODULE}`. The design already names this and takes the repetition on purpose. Fine to leave. A `soma_tool:to_manifest/1` helper would collapse it if the adapter pair ever grows.
- `soma_tool_manifest_tests.erl` repeats the five-module list in three tests and `soma_run_happy_path_SUITE` repeats it twice more. If a sixth built-in lands, five lists need editing. A shared `builtin_modules()` helper per file would cut that.

## Functional evidence
- Criterion 1 — pass: `test_builtin_manifests_normalize` in `apps/soma_tools/test/soma_tool_manifest_tests.erl` calls `soma_tool_manifest:normalize(Module:manifest())` live for `soma_tool_echo`, `soma_tool_sleep`, `soma_tool_fail`, `soma_tool_file_read`, `soma_tool_file_write` and asserts `{ok, _}`. No fixture — the manifest comes from each module's exported `manifest/0`.
- Criterion 2 — pass: `test_builtin_manifest_metadata_matches_describe` compares `maps:with([name, effect, idempotent, timeout_ms], Manifest)` against the same projection of `Module:describe()` for all five built-ins. `manifest/0` is `(describe())#{adapter => ..., module => ...}`, so the four values hold by construction.
- Criterion 3 — pass: `test_builtin_manifest_names_erlang_module_adapter` asserts `maps:get(adapter, Manifest) =:= erlang_module` and `maps:get(module, Manifest)` is the backing module for each of the five tools.
- Criterion 4 — pass: `test_registry_seeds_descriptors_from_manifests` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl` runs against the booted runtime and asserts `soma_tool_registry:resolve_descriptor(Name) =:= {ok, normalize(Module:manifest())}` for each built-in. `soma_tool_registry:seed/0` folds `?BUILTIN_MODULES` through `soma_tool_manifest:normalize/1`, replacing the old `?SEED` literal. `soma_run.erl:67` still reads `module` by key, so widening the descriptor is safe.
- Criterion 5 — pass: `rebar3 eunit` reports `47 tests, 0 failures`; `rebar3 ct` reports `All 31 tests passed.` at branch HEAD b952d2a.
