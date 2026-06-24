### Claude

## Verdict
changes-requested

## Real issues

**1. No implementation — design doc only.**
The branch adds `design-40.md` and nothing else. Zero acceptance criteria are met. The review below is of the design's correctness, not of shipped code.

**2. `parse_args` does not guard against the mixed `(from_step ...) + extra` case.**
The design says a multi-element `(args ...)` list that starts with `[from_step, _]` "should fall through to the existing catch-all error." It does not, under the current `parse_args` clause shape. `[[from_step, id1], [extra, foo]]` hits the `[[Key, Value] | Rest]` clause with `Key = from_step`, silently emitting `from_step => coerce_value([id1])` as a field key — that is wrong and silent. The bare `from_step` clause must be `[[from_step, Id]]` (exact single-element list match, not just head match), so a two-element list falls past it into the key-value loop and then the catch-all. The design describes the right outcome but does not lock in the pattern that achieves it. Dev must use a strict single-element match, not `[[from_step, Id] | _]`.

**3. Existing test in `soma_lfe_parse_tests` asserts `timeout_ms => 5000` from the accumulator default.**
`test_valid_run_form_produces_internal_repr` (line 8) passes source that includes `(timeout_ms 5000)` explicitly, so it survives the default removal. That is fine. The design says "existing EUnit tests will be updated" but does not identify which assertions change. Dev must audit all callers of `compile/2` in the test files and confirm none rely on the implicit 5000 — `soma_lfe_parse_tests.erl` line 8-16 is the only test using `timeout_ms` and it is safe, but this needs explicit verification in the PR, not a blanket statement.

**4. Criterion 4 test proves shape, not runtime compatibility.**
The design explicitly scopes the test to `is_list(Steps)` + `is_map` per element. That does not prove `soma_run` will accept the step list — `soma_run` also requires the `id` and `tool` keys to be atoms, and `args` to be a map. A step with `#{id => <<"s1">>, tool => <<"echo">>, args => #{}}` passes the structural check but fails at runtime. The test should assert `is_atom(maps:get(id, Step))` and `is_atom(maps:get(tool, Step))` at minimum, or acknowledge the gap explicitly. As written, Criterion 4 gives false confidence.

## Questions

- The design says `soma_agent_session:start_run/2` "takes a plain list." Verify this is still true after v0.2 manifest changes — confirm the function signature in `soma_agent_session.erl` hasn't grown a validation layer that would reject steps without `timeout_ms`. (A quick grep confirms `start_run` just stores and forwards, so this is low risk, but worth a line in the PR.)

## Nits

- `coerce_value([from_step, Id])` — add a module comment in `soma_lfe_parser.erl` before shipping, as the design itself notes. One sentence is enough: "A two-element list headed by `from_step` is the only list shape `coerce_value` transforms; all other lists are invalid DSL and should not reach this function."
- The design calls `soma_lfe.erl` the "public boundary that threads both together." The module doc in `soma_lfe.erl` already says this. No action needed, just confirming it stays consistent.

## Functional evidence
- Criterion 1 — fail: no implementation; `soma_lfe_compile_tests.erl` does not exist
- Criterion 2 — fail: no implementation; `parse_args` and `coerce_value` are unchanged from main
- Criterion 3 — fail: no implementation; `parse_step_children` still initializes `#{args => #{}, timeout_ms => 5000}` at line 52 of `soma_lfe_parser.erl`
- Criterion 4 — fail: no implementation; `soma_lfe_compile_tests.erl` does not exist
- Criterion 5 — fail: no implementation; no `?assertEqual` assertions on full output maps exist in any new test module
