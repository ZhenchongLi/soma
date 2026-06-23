### Claude

## Verdict
approve

## Real issues

None.

## Questions

- `module => "str"` (a non-atom module reference) passes as `{ok, ...}`. Design step 6 said "`module` is present **and is an atom**", but the implementation only checks `maps:is_key(module, ...)`. No acceptance criterion requires the type check — criterion 8 is about *missing*, which is rejected — so this is not a blocker. Flagging it because the registry will eventually call `Module:invoke/2`; a string there crashes at call time, not manifest time. Worth a follow-up issue if the manifest is meant to be the gate.

## Nits

- Each `normalize_complete/1` clause re-destructures the same keys it just pattern-matched, then rebuilds an identical map. `maps:with(Keys, Manifest)` would express "keep exactly these keys" in one line and make the canonical key set a data value instead of two hand-copied literals. Correct as written.

## Functional evidence
- Criterion 1 — pass: `test_normalize_accepts_erlang_module` asserts `normalize/1` returns `{ok, Manifest}` for the well-formed `erlang_module` map (`name=file_read, effect=reader, idempotent=true, timeout_ms=1000, adapter=erlang_module, module=soma_tool_file_read`); 13 tests, 0 failures.
- Criterion 2 — pass: `test_normalize_accepts_cli` asserts `{ok, Manifest}` for the well-formed `cli` map (`executable="echo", argv=["hi"]`); green.
- Criterion 3 — pass: `test_normalize_rejects_missing_shared_field` removes each of `name, effect, idempotent, timeout_ms, adapter` in turn and asserts `{error, {missing_field, Key}}`; green.
- Criterion 4 — pass: `test_normalize_rejects_bad_effect` asserts `effect=destroyer` yields `{error, {invalid_effect, destroyer}}`; green.
- Criterion 5 — pass: `test_normalize_rejects_non_boolean_idempotent` asserts `idempotent=yes` yields `{error, {invalid_idempotent, yes}}`; green.
- Criterion 6 — pass: `test_normalize_rejects_bad_timeout_ms` asserts `0`, `-1`, and `"1000"` each yield `{error, {invalid_timeout_ms, Value}}`; green.
- Criterion 7 — pass: `test_normalize_rejects_unknown_adapter` asserts `adapter=grpc` yields `{error, {invalid_adapter, grpc}}`; green.
- Criterion 8 — pass: `test_normalize_rejects_erlang_module_without_module` asserts an `erlang_module` map with `module` removed yields `{error, {missing_field, module}}`; green.
- Criterion 9 — pass: `test_normalize_rejects_shell_string_executable` asserts `"echo"`, `"/bin/echo"`, `<<"/bin/echo">>` pass and `"echo hi"`, `"/bin/sh -c 'echo hi'"`, `"echo\thi"`, `<<"echo hi">>` yield `{error, {invalid_executable, Value}}`; green.
- Criterion 10 — pass: `test_normalize_rejects_non_list_argv` asserts `not_a_list`, `<<"hi">>`, `#{}`, `42` each yield `{error, {invalid_argv, Value}}`; green.
- Criterion 11 — pass: `test_reject_reason_names_field` runs eight malformed manifests and asserts the field atom (`name, effect, idempotent, timeout_ms, adapter, module, executable, argv`) appears in each reason tuple; green.
- Criterion 12 — pass: `test_normalize_is_idempotent` feeds both adapters a manifest carrying a `stray` key, normalizes to `M2`, and asserts `normalize(M2) == {ok, M2}` — the stray key is dropped on the first pass and the second pass is a fixpoint; green.
