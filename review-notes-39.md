### Claude

## Verdict
approve

## Real issues
None.

## Questions

1. `list_to_atom/1` at `soma_lfe_reader.erl:101` creates a new atom for every distinct identifier it sees. The 255-char guard prevents `system_limit`, but a caller feeding many short distinct names can exhaust the atom table (default cap: 1,048,576 atoms) and crash the VM. For a development-time compiler reading trusted source this is acceptable. If this path ever handles untrusted input in a long-running node, swap to `list_to_existing_atom` for the keyword set (run, step, args, timeout_ms) and keep `list_to_atom` only for those; reject everything else as an unknown identifier.

2. `parse_all_forms/3` at `soma_lfe_reader.erl:119` — the fourth clause (`_Stack` non-empty) is unreachable. Every call site passes `[]` as the third argument (line 21, line 115). The branch reads as a planned stack-based approach that was abandoned. Delete it or collapse to `parse_all_forms/2`. No correctness impact.

3. First clause of `compile/2` at `soma_lfe.erl:15` uses `_Opts` (underscore-prefixed, signalling "unused") but then passes `_Opts` into the recursive call at line 16. The code works — in Erlang `_Opts` is still bound — but the underscore misleads. Rename to `Opts` in that clause.

## Nits

- `scan_integer` does not guard that the first char after the digits is a valid delimiter. `1abc` scans as integer `1` then atom `abc`. The parser rejects the result, but the diagnostic says "missing id or tool" rather than "1 is not a valid identifier." Wrong message for a wrong input. Tolerable for now.

## Functional evidence
- Criterion 1 — pass: `valid_run_form_produces_internal_repr_test` in `apps/soma_lfe/test/soma_lfe_parse_tests.erl` calls `soma_lfe:compile/2` with `(run (step s1 echo (args (message "hello")) (timeout_ms 5000)))` and pattern-matches `#{run := #{steps := [#{id := s1, tool := echo, args := #{message := <<"hello">>}, timeout_ms := 5000}]}}`. EUnit: 83 tests, 0 failures.
- Criterion 2 — pass: `multiple_top_level_forms_fail_test` feeds two `(run ...)` forms and asserts `{error, [#{message => _, line => _} | _]}`. EUnit: 83 tests, 0 failures.
- Criterion 3 — pass: `non_run_top_level_form_fails_test` feeds `(define foo 1)` and asserts `{error, [#{message => _, line => _} | _]}`. EUnit: 83 tests, 0 failures.
- Criterion 4 — pass: `unknown_step_child_form_fails_test` feeds `(run (step s1 echo (unknown_form)))` and asserts `{error, [#{message => _, line => _} | _]}`. EUnit: 83 tests, 0 failures.
- Criterion 5 — pass: `parse_does_not_start_runtime_test` asserts `whereis(soma_sup) =:= undefined` before and after `compile/2`. The `soma_lfe` app's `.app.src` declares only `[kernel, stdlib]`; `soma_runtime` is absent. EUnit: 83 tests, 0 failures. CT: 61 tests, 0 failures.
