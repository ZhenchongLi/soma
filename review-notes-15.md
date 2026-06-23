### Claude

## Verdict
changes-requested

## Real issues

- `normalize/1` crashes with `function_clause` on a `cli` manifest that omits `executable` or `argv`. Three shapes blow up instead of returning `{error, _}`:
  - `cli` with `executable` but no `argv`
  - `cli` with neither `executable` nor `argv`
  - `cli` with `argv` but no `executable`

  `check_adapter_fields/1` at `apps/soma_tools/src/soma_tool_manifest.erl:60` and the fall-through clause at `:65` route these maps into `normalize_complete/1`, whose cli clause at `:90` requires both `executable :=` and `argv :=`. No match, so the call throws. Reproduced:

  ```
  cli executable no argv => {'EXIT',{function_clause,[{soma_tool_manifest,normalize_complete,...,{line,73}}...]}}
  cli no executable no argv => {'EXIT',{function_clause,...}}
  cli argv no executable => {'EXIT',{function_clause,...}}
  ```

  The `-spec` says `normalize(map()) -> {ok, map()} | {error, term()}`. The function violates its own spec. `docs/tool-manifest.md` says a `cli` entry carries both `executable` and `argv`; a cli manifest missing either is malformed and must be rejected with `{error, {missing_field, executable}}` / `{error, {missing_field, argv}}`, not a crash. Any caller handing the validator a half-built cli manifest takes down the calling process instead of getting a reason. Add `executable` and `argv` to the cli-adapter required-field check.

## Questions

None.

## Nits

- Each `normalize_complete/1` clause re-destructures the same six or seven keys it just pattern-matched, then rebuilds an identical map. `maps:with(Keys, Manifest)` would express "keep exactly these keys" in one line and make the canonical key set a data value rather than two hand-copied literals. Not load-bearing — the current form is correct for the shapes it accepts.

## Functional evidence
- Criterion 1 — pass: `test_normalize_accepts_erlang_module` asserts `normalize/1` returns `{ok, Manifest}` for the well-formed `erlang_module` map (`name=file_read, effect=reader, idempotent=true, timeout_ms=1000, adapter=erlang_module, module=soma_tool_file_read`); 12 tests, 0 failures.
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
