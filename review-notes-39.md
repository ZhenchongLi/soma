### Claude

## Verdict
changes-requested

## Real issues

1. `list_to_atom/1` in `soma_lfe_reader:scan_atom/4` (line 95) crashes with `system_limit` for any atom name longer than 255 characters. The function's contract is `{ok, [term()]} | {error, [diagnostic()]}`. A `system_limit` exception violates that contract — the caller gets a crash, not `{error, Diags}`. Fix: use `list_to_existing_atom` for known keywords, or catch the `system_limit` error and return a diagnostic. (Reproducer: `soma_lfe:compile(<<"(run (step ", (binary:copy(<<"a">>, 256))/binary, " echo))">>, #{})` kills the calling process.)

## Questions

1. `scan_integer` does not check that the character immediately after the digits is a valid delimiter (whitespace, paren, or end of input). `1abc` scans as two tokens: integer `1` then atom `abc`. The parser downstream happens to reject the result with an error, but the error message — "step form must be (step <id> <tool> ...): missing id or tool" — is wrong. The real error is that `1` is not a valid step id. Not a correctness bug (it still errors), but the diagnostic misleads. Worth fixing in a follow-up.

2. The `_Stack` parameter in `parse_all_forms/3` is always `[]`. The clauses at lines 103–104 and 112–113 — the non-empty-stack branches — are dead code. They read as if a stack-based accumulator was planned but abandoned. These lines should either be deleted or the signature simplified to `parse_all_forms/2`. Low priority, but leaving vestigial clauses in a new module is noise.

## Nits

- `parse_run/1` in `soma_lfe_parser.erl`, line 26: the `[Form] when is_list(Form)` clause is unreachable. By the time the reader hands a list form to the parser, it is already unwrapped (reader returns Erlang lists, not tagged tokens). The `[Form] when is_list(Form)` and `[_Form]` clauses at lines 26–29 both map to "empty list or atom-headed list we didn't catch above." The dead clause doesn't affect correctness, but it adds noise.

## Functional evidence
- Criterion 1 — pass: `valid_run_form_produces_internal_repr_test` in `apps/soma_lfe/test/soma_lfe_parse_tests.erl` calls `soma_lfe:compile/2` with `(run (step s1 echo (args (message "hello")) (timeout_ms 5000)))` and asserts the result is `#{run => #{steps => [#{id => s1, tool => echo, args => #{message => <<"hello">>}, timeout_ms => 5000}]}}`. EUnit: 5/5 pass.
- Criterion 2 — pass: `multiple_top_level_forms_fail_test` in `apps/soma_lfe/test/soma_lfe_parse_tests.erl` feeds two `(run ...)` forms and asserts `{error, [#{message => _, line => _} | _]}`. EUnit: 5/5 pass.
- Criterion 3 — pass: `non_run_top_level_form_fails_test` in `apps/soma_lfe/test/soma_lfe_parse_tests.erl` feeds `(define foo 1)` and asserts `{error, [#{message => _, line => _} | _]}`. EUnit: 5/5 pass.
- Criterion 4 — pass: `unknown_step_child_form_fails_test` in `apps/soma_lfe/test/soma_lfe_parse_tests.erl` feeds `(run (step s1 echo (unknown_form)))` and asserts `{error, [#{message => _, line => _} | _]}`. EUnit: 5/5 pass.
- Criterion 5 — pass: `parse_does_not_start_runtime_test` in `apps/soma_lfe/test/soma_lfe_parse_tests.erl` asserts `whereis(soma_sup) =:= undefined` before and after `compile/2`. The `soma_lfe` app's `.app.src` lists only `[kernel, stdlib]` as dependencies; `soma_runtime` is absent. EUnit: 5/5 pass.
