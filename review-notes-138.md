### Claude

## Verdict
approve

## Real issues

None.

## Questions

None.

## Nits

- The malformed-reject diagnostic carries `line => 0`, like every other proposal
  diagnostic. The criterion only wants the key present, so this is fine. The
  design already flags it as a parser-wide change for later.
- `(reject (reason))` reuses the generic `malformed proposal form: 'reject'`
  message. It names the head but not the missing reason string. Matches the reply
  path. No change needed in this slice.

## Functional evidence
- Criterion 1 — pass: `test_reject_form_compiles_to_reject_kind` calls `soma_lfe:compile(<<"(reject (reason \"tool not allowed\"))">>, #{})`, asserts `kind => reject`, `reason => <<"tool not allowed">>`, and `is_binary(Reason)`. Green in `rebar3 eunit` (7 tests, 0 failures).
- Criterion 2 — pass: `test_reject_form_normalizes_to_reject_kind` feeds the real `soma_lfe:compile/2` output into the real `soma_proposal:normalize/1`, asserts the normalized map keeps `kind => reject` and the same reason binary. `soma_proposal.erl:26` clause `normalize(#{kind := reject, reason := Reason}) when is_binary(Reason)` accepts it. No layer bypassed.
- Criterion 3 — pass: `test_malformed_reject_form_returns_diagnostic` calls `soma_lfe:compile(<<"(reject (reason))">>, #{})`. The form `[reject, [reason]]` misses the reject clause (line 110, guard needs `[reason, Reason]`), falls through to the `[Head | _]` catch-all at `soma_lfe_parser.erl:121`, returns `{error, [Diag | _]}` with binary `message` and `line` key. Test asserts both keys and `is_binary(message)`. No crash.
- Criterion 4 — pass: `soma_lfe.erl:33` adds `dispatch([[reject | _] = Form]) -> soma_lfe_parser:parse_proposal(Form)`, placed beside the `reply` and `run-steps` clauses and before the catch-all `dispatch(Forms)`. Criterion 1's reject-map result proves routing reached `parse_proposal/1`, not the run path.
- Criterion 5 — pass: `docs/contracts/L.3-test-contract.md` gains a reject-form section + proof table, `docs/lfe-dsl.md` adds the `(reject (reason "..."))` → `#{kind => reject, reason => ...}` grammar row, `docs/lisp-messages.md` adds the form to the proposal-form line. `test_docs_document_reject_form` asserts each file contains the form string; green in `rebar3 eunit`.
