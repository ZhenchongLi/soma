### Claude

## Verdict
changes-requested

## Real issues

**Silent data loss when bare `from_step` is not the first arg entry.**

`soma_lfe_parser.erl` line 87: `parse_args([[from_step, Id]], _Acc)` matches when the remaining list is exactly one element. It discards `_Acc`. This is safe when `from_step` is the only arg, but breaks when other keys appear first. For `(args (path "x") (from_step s1))` the recursion trace is:

1. `parse_args([[path, <<"x">>], [from_step, s1]], #{})` — key-value clause fires, accumulates `#{path => <<"x">>}`
2. `parse_args([[from_step, s1]], #{path => <<"x">>})` — bare clause fires, discards `Acc`, returns `#{from_step => s1}`

`path` silently disappears. No diagnostic. The design doc raised this as a risk but the fix it calls for ("a two-or-more element list that starts with `[from_step, _]` should fall through to the existing catch-all error") only covers the case where `from_step` is first. The trailing case is unaddressed.

Fix: add a guard so the bare clause only fires when `Acc` is still empty:

```erlang
parse_args([[from_step, Id]], Acc) when map_size(Acc) =:= 0 ->
    {ok, #{from_step => Id}};
```

When `Acc` is non-empty, the head `[from_step, Id]` is a two-element list with atom key `from_step` — it falls through to the `[[Key, Value] | Rest]` clause and `coerce_value([from_step, Id])` returns `{from_step, Id}`, which is also wrong semantically (bare `from_step` as a field value). So the right behavior for a non-empty accumulator ending in `[from_step, Id]` is the catch-all error. The `map_size(Acc) =:= 0` guard gets there: the key-value clause fires first for the prior keys, then the bare clause fails the guard, then the malformed-key clause fires with `Key = from_step`. Add a test proving this errors rather than silently dropping prior keys.

## Questions

**Criterion 4's test scope.** The test never calls `soma_agent_session:start_run/2` — only checks `is_list`, `is_map`, `is_atom`. The design justified this as structural-only since booting the runtime is out of scope. The criterion says "can be passed directly" and the test proves the shape `start_run/2` guards (`when is_list(Steps)`) and `soma_run` requires (`is_atom(id)`, `is_atom(tool)`, `is_map(args)`). Acceptable scope.

## Nits

- `coerce_value([from_step, Id])` is a covert exception in a function that otherwise passes values through. The design noted it should get a module comment. One line would do: "List values headed by `from_step` are the only lists this function transforms."
- The test for criterion 4 checks `is_map(maps:get(args, Step))` but the bare-`from_step` step's args (`#{from_step => read}`) is also a map — so all three steps pass the same structural assertion even though they have different shapes. That's fine, but it means the test does not distinguish bare-`from_step` from field-level. No action needed.

## Functional evidence

- Criterion 1 — pass: `three_step_demo_compiles_test` in `apps/soma_lfe/test/soma_lfe_compile_tests.erl` uses `?assertEqual` on the exact three-element step list; `rebar3 eunit --module=soma_lfe_compile_tests` reports 4 tests, 0 failures.
- Criterion 2 — pass: `from_step_shapes_compile_test` asserts bare form produces `#{from_step => read}` and field-level produces `#{content => {from_step, process}, path => <<"out.txt">>}`; both match the `resolve_args/2` branch shapes at `soma_run.erl:337-340`.
- Criterion 3 — pass: `timeout_ms_omitted_when_absent_test` asserts `?assertNot(maps:is_key(timeout_ms, Step))`; accumulator in `parse_step_children` now starts as `#{args => #{}}` at `soma_lfe_parser.erl:52`, confirmed in diff.
- Criterion 4 — pass: `output_satisfies_start_run_contract_test` asserts `is_list(Steps)` and per-step `is_map`, `is_atom(id)`, `is_atom(tool)`, `is_map(args)` — matching the `start_run/2` guard at `soma_agent_session.erl:24` and the field requirements `soma_run` reads at runtime. Structural check only; runtime execution not exercised (in scope per design).
- Criterion 5 — pass: both `test_three_step_demo_compiles` and `test_from_step_shapes_compile` use `?assertEqual` on full expected maps with concrete values.
