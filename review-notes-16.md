### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `resolve/1` now survives only to keep `test_registry_seeded_with_v01_tools` green. The design says #17 retires it once nothing pins the bare-module shape. Fine for this issue. Just don't let it linger past #17.

## Nits
- `start_tool_call/7` takes seven positional args. `Step` and `StepId` both ride along when `StepId` is `maps:get(id, Step)`. Passing `Step` alone and deriving `StepId` inside would drop one arg. Not worth a round; mentioning for the next time the function gets touched.

## Functional evidence
- Criterion 1 — pass: `?SEED` in `soma_tool_registry.erl` stores `echo => #{adapter => erlang_module, module => soma_tool_echo}` and four siblings; `-type descriptor() :: #{adapter := erlang_module, module := module()}` declares the shape, reusing the `adapter` vocabulary from `docs/tool-manifest.md` rather than a new field.
- Criterion 2 — pass: `register/3` stores the descriptor verbatim and `lookup/2` returns `{ok, Descriptor}`; `test_register_lookup_returns_descriptor` asserts `?assertEqual({ok, Descriptor}, lookup(Registry, echo))` where `Descriptor = #{adapter => erlang_module, module => soma_tool_echo}` — the map, not a bare atom. EUnit: 44 tests, 0 failures.
- Criterion 3 — pass: `test_registry_resolves_erlang_module_descriptors` loops `[echo, sleep, fail, file_read, file_write]` through the running `resolve_descriptor/1`, asserting `erlang_module = maps:get(adapter, Descriptor)` and `is_atom(maps:get(module, Descriptor))` for each. CT green.
- Criterion 4 — pass: `executing/3` matches `{ok, #{module := Module}}` from `resolve_descriptor/1` and hands `Module` to `soma_tool_call:start`. `test_demo_file_read_echo_file_write` asserts `run.completed` is recorded and that for each demo tool the descriptor-read module equals `resolve/1`'s module. CT: all 30 tests passed.
- Criterion 5 — pass: `executing/3` branches on `{error, not_found}` into `fail_run(Data, Step, ToolCallId, undefined, {unregistered_tool, ToolName})`, no blind `{ok, Module}` match. `test_unregistered_tool_reaches_failed_not_crash` runs a step naming `no_such_tool`, then asserts `run.failed` present, `run.completed` absent, the fail event carries a `reason` payload, `is_process_alive(RunPid)` true, and the session reports `failed`. CT green.
- Criterion 6 — pass: both suites run unchanged except the two added cases. `rebar3 ct` reports `All 30 tests passed`; `rebar3 eunit` reports `44 tests, 0 failures`. `resolve/1` keeps its bare-module shape so `test_registry_seeded_with_v01_tools` passes without edit.
