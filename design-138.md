# [cc] L.3.1: Lisp (reject (reason ...)) proposal form

## Current state

The Lisp DSL parses two proposal forms. `soma_lfe:dispatch/1` routes a top-level
`(reply ...)` or `(run-steps ...)` form to `soma_lfe_parser:parse_proposal/1`,
which builds `#{kind => reply, text => ...}` or `#{kind => run_steps, steps => ...}`.
There is no clause for `(reject ...)`, and `dispatch/1` has no clause for a
`reject` head either.

The internal proposal model is already ahead of the DSL. `soma_proposal:normalize/1`
has a clause `normalize(#{kind := reject, reason := Reason}) when is_binary(Reason)`
since v0.5.2. So the actor and policy layers can already handle a reject proposal —
the only thing missing is a way for an LLM to express one in Lisp source.

If an LLM emits `(reject (reason "..."))` today, the reader produces the raw form,
`dispatch/1` falls through to its catch-all `parse_run(Forms)` clause, and the
source is treated as a run instead of a reject. The Lisp proposal surface is out
of sync with the model it compiles down to.

## Approach

Add `reject` on the same two seams the existing proposal forms use.

First, `soma_lfe:dispatch/1` gets a clause that matches a single `[reject | _]`
top-level form and sends it to `soma_lfe_parser:parse_proposal/1`. This sits next
to the existing `reply` and `run-steps` clauses, so all three proposal kinds route
through one parser.

Second, `parse_proposal/1` gets a clause for the reject shape:

- `parse_proposal([reject, [reason, Reason]]) when is_binary(Reason)` returns
  `{ok, #{kind => reject, reason => Reason}}`.

The reason arrives as a binary already, because the reader turns a Lisp string
literal into an Erlang binary (same as `(text "...")` in the reply clause). No
conversion is needed.

A malformed reject — `(reject (reason))` with no string — does not match the new
clause. It falls through to the existing `parse_proposal([Head | _])` catch-all,
which returns `{error, [Diagnostic]}` with a `message` and a `line` key. That
catch-all already exists for malformed reply forms, so the malformed reject path
reuses it without new code. The compiler returns a diagnostic, it does not crash.

This mirrors the reply path exactly. Compile-only: no processes, no events, and
`soma_runtime` does not import `soma_lfe`.

The diagnostics today carry `line => 0` (the parser does not yet thread source
line numbers). Criterion 3 only requires the `line` key to be present and the
`message` to be a binary, which the existing catch-all satisfies. We do not change
the line-number behavior in this slice.

Docs get the new form: `docs/contracts/L.3-test-contract.md` (the proof for the
reject form), `docs/lfe-dsl.md` (the grammar entry), and `docs/lisp-messages.md`
(the proposal-form reference).

## Acceptance criteria → tests

### Criterion 1 — (reject (reason "...")) compiles to a reject map with a binary reason
- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe:dispatch/1` (new `[reject | _]` clause) →
  `soma_lfe_parser:parse_proposal/1` (new reject clause)
- Test entry: `soma_lfe:compile/2` (no layer bypassed)
- Test: `test_reject_form_compiles_to_reject_kind` in
  `apps/soma_lfe/test/soma_lfe_proposal_tests.erl`

### Criterion 2 — compiled reject map normalizes through soma_proposal
- Call chain: `soma_lfe:compile/2` → `soma_lfe_parser:parse_proposal/1` →
  `soma_proposal:normalize/1` (existing reject clause)
- Test entry: `soma_lfe:compile/2`, then the returned map is fed to the real
  `soma_proposal:normalize/1` (no layer bypassed — the test wires the two real
  functions together exactly as the actor would)
- Test: `test_reject_form_normalizes_to_reject_kind` in
  `apps/soma_lfe/test/soma_lfe_proposal_tests.erl`

### Criterion 3 — malformed reject returns a diagnostic, no crash
- Call chain: `soma_lfe:compile/2` → `soma_lfe:dispatch/1` →
  `soma_lfe_parser:parse_proposal/1` (falls through to the existing
  `[Head | _]` catch-all)
- Test entry: `soma_lfe:compile/2` (no layer bypassed)
- Test: `test_malformed_reject_form_returns_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_proposal_tests.erl`

### Criterion 4 — a (reject ...) form routes to the proposal parser
- Call chain: `soma_lfe:compile/2` → `soma_lfe:dispatch/1` (the new `[reject | _]`
  clause picks the form before the catch-all `parse_run/1`)
- Test entry: `soma_lfe:compile/2` (no layer bypassed). Criterion 1's success
  result proves routing reached `parse_proposal/1` — a reject map came back, not a
  run map, which only the new dispatch clause produces. No separate test is needed
  beyond Criterion 1.
- Test: covered by `test_reject_form_compiles_to_reject_kind` (same file)

### Criterion 5 — docs cover the (reject (reason ...)) form
- Call chain: none (direct source-file read)
- Test entry: not a runtime path — these are doc files reviewed by eye
- Test: `docs/contracts/L.3-test-contract.md`, `docs/lfe-dsl.md`,
  `docs/lisp-messages.md` each gain the reject entry

## Risks & trade-offs

The malformed-reject diagnostic reuses the generic `malformed proposal form`
catch-all, so `(reject (reason))` gets the same message as a malformed reply. The
message names the head atom (`reject`) but not the missing `reason` string. That
is less precise than a reject-specific message, but it matches how the reply path
already behaves and keeps the change small. A dedicated message would mean a new
clause that only fires for this one error shape.

The `line` key stays `0`. The criterion accepts that, but a reader emitting a
real source line would be more useful for an LLM debugging its own output. That
is a parser-wide change, out of scope here.
