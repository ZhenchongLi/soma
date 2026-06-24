### Claude

## Verdict
changes-requested

## Real issues

**1. `test_from_step_shapes_compile` breaks the moment `invalid_from_step` validation lands.**

`apps/soma_lfe/test/soma_lfe_compile_tests.erl`, lines 32–44.

Both sub-cases in that test compile a single-step run that references a step id that does not exist in the run:

- `BareSource`: step `s2` has `(from_step s1)`, but `s1` is never defined. The test asserts `{ok, ...}`.
- `FieldSource`: step `s3` has `(content (from_step s2))`, but `s2` is never defined. The test asserts `{ok, ...}`.

Once the design's `invalid_from_step` check runs, both return `{error, [{code => invalid_from_step, ...}]}`. The test pattern-matches on `{ok, ...}`, so it crashes with a badmatch.

The design does not mention this. Dev must either update those two sub-cases to use valid back-references, or split them into a "shapes compile" test and a separate "unknown reference is rejected" test. Leaving them as-is means the suite goes red the moment the validation pass is added.

## Questions

- The design maps AC criterion 2 ("unknown or forward `from_step` references") into two separate tests (design criterion 2 = forward, design criterion 3 = unknown), and then maps AC criterion 5 ("multiple diagnostics") and AC criterion 6 ("does not create a run") into design criteria 6 and 7 respectively. That's fine, but the numbering diverges from the AC. The functional-evidence block below uses AC numbering.

- Design section 4 says the positive-integer check closes the gap where `timeout_ms 0` or a negative value slips through. Currently the parser's `[[timeout_ms, N] | Rest] when is_integer(N)` clause accepts any integer, including 0 and negatives. The fix needs a guard split: accept when `is_integer(N), N > 0`; return `invalid_timeout` otherwise. That's straightforward, but confirm that the existing `test_valid_run_form_produces_internal_repr` test (timeout_ms 5000) still passes after the guard tightens — it should, 5000 > 0.

## Nits

- The design says "No new module is needed" and then immediately says "No new module is created" — redundant, one sentence is enough.

- `parse_steps` accumulation (design section 6): the description "stop the moment it sees the first error across steps" is the current behavior; the design correctly calls this out. The implementation note about separating "cannot parse step shape" from "parsed but semantic error" is the key complexity. Worth a code comment in the implementation, not just the design doc.

- The reader diagnostics (`code => scan_error`, `code => parse_error`) are described as "not under test" — that's fine for now, but they should be consistent. Flag for whoever adds reader tests later.

## Functional evidence

- Criterion 1 — fail: no implementation exists on this branch; `soma_lfe_parser` has no `code` field on any diagnostic and no duplicate-id check.
- Criterion 2 — fail: no `invalid_from_step` validation exists; `coerce_value([from_step, Id])` in `soma_lfe_parser` line 107 returns `{from_step, Id}` without checking whether `Id` names an earlier step.
- Criterion 3 — fail: same as criterion 2 — no timeout positivity check; `parse_step_children` line 71 accepts any integer, including 0 and negatives.
- Criterion 4 — fail: no `code => unknown_form` field on any diagnostic; `parse_step_children` lines 73–83 emit `message`-only diagnostics.
- Criterion 5 — fail: no multi-diagnostic accumulation; `parse_steps` lines 38–39 return `{error, Diags}` on first bad step and discard `Acc`.
- Criterion 6 — fail: no `soma_lfe_validation_tests.erl` file exists on this branch.
