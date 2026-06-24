# [v0.3] Validate DSL and return structured diagnostics

## Current state

The `soma_lfe` app has three layers: `soma_lfe_reader` scans+parses LFE source
into Erlang terms, `soma_lfe_parser` walks those terms into a step list, and
`soma_lfe` is the public boundary that calls both.

The parser already rejects many bad inputs — wrong top-level form, non-atom step
ids, wrong child forms inside `(step ...)`, malformed arg pairs, and the
`(from_step ...)` guard added in #40. What it does not do:

- carry a stable `code` atom in diagnostics (current shape is
  `#{message => binary(), line => non_neg_integer()}` — no `code` field, so
  tests must either match strings or use `assertMatch({error, _})`);
- detect duplicate step ids;
- detect forward or unknown `from_step` references (the parser coerces
  `(from_step Id)` to `{from_step, Id}` without checking whether `Id` names an
  earlier step);
- reject a non-positive or non-integer `timeout_ms`;
- collect multiple diagnostics in one pass when more than one error is present.

The runtime (`soma_agent_session:start_run/2`) accepts a raw step list from any
caller and starts `soma_run` immediately. It does its own runtime-level defensive
checks inside `soma_run` (e.g. unregistered tool → `fail_run`), but those happen
after the run has started and events have been emitted. Nothing stops a caller
from passing a step list with duplicate ids or a dangling `from_step` reference
straight to `start_run`.

## Approach

### 1. Add a `code` field to every diagnostic

Change the diagnostic type in `soma_lfe_parser` to:

```erlang
#{code => atom(), message => binary(), line => non_neg_integer()}
```

Every existing `{error, [#{message => ..., line => ...}]}` site gets a `code`
atom. The specific codes the issue names — `duplicate_step_id`,
`unknown_form`, `invalid_from_step`, `invalid_timeout`, `invalid_step` — map
one-to-one to the validation rules below. Keep the `message` and `line` fields;
tests must not depend on message strings, but humans and logs still benefit from
them.

No new module is needed. The change stays inside `soma_lfe_parser` and any
reader diagnostics that bubble through `soma_lfe`. The reader's own diagnostics
can carry `code => scan_error` for the scanner faults and `code => parse_error`
for structural reader faults; those codes are not under test by the AC criteria
but should be consistent with the new shape.

### 2. Duplicate step id check

After parsing all steps, walk the id list and find duplicates. Return
`{error, [#{code => duplicate_step_id, ...}]}` for each duplicate found. This
means the step list is fully parsed first, then validated — which lets the parser
collect all structural errors in one pass before the semantic check runs.

### 3. Forward and unknown `from_step` reference check

After the duplicate-id check passes, walk the step list in order. Maintain a set
of seen ids. When a step's args contain a `{from_step, Id}` value (at any depth),
check that `Id` is in the seen set. If it is not — either because it names a
later step or a step that does not exist at all — return
`{error, [#{code => invalid_from_step, ...}]}`. Add the current step's id to the
seen set after processing its args, so that self-reference is also rejected.

Both forward references and unknown references get the same code. The message can
spell out which case applies; the code stays the same because callers should not
need to distinguish them in their error-handling logic.

### 4. Invalid `timeout_ms` check

The parser currently accepts `(timeout_ms N)` only when `N` is already an
integer (the reader produces integers for integer literals). It silently falls
through to the "unknown step child form" error if the token is not an integer.
Add an explicit clause for `(timeout_ms N)` where `N` is not a positive integer,
returning `#{code => invalid_timeout, ...}`. The positive-integer check (`N > 0`)
closes the gap where `timeout_ms 0` or a negative value slips through.

### 5. Unknown form codes

The existing "unknown step child form" and "run child form must be 'step'" errors
get `code => unknown_form`. The existing "step form must be ..." error gets
`code => invalid_step`.

### 6. Multi-diagnostic collection

Structural errors (wrong head atom, malformed token) still stop parsing the
current step early — there is no point continuing to parse a step whose shape is
unrecognizable. But at the step-list level, `parse_steps` can accumulate errors
across steps rather than returning on the first bad step. This lets a source file
with three bad steps return three diagnostics instead of one. The from_step and
duplicate-id passes can also accumulate and return all violations at once.

This is a best-effort improvement, not a hard requirement. The AC says "multiple
diagnostics can be returned when practical" — so the design does not require that
every possible combination always produces every possible diagnostic, only that
the parser does not stop the moment it sees the first error across steps.

### 7. No runtime changes

The validation change is entirely inside `soma_lfe` and `soma_lfe_parser`. The
runtime (`soma_agent_session`, `soma_run`) is unchanged. A caller who submits a
bad step list directly to `start_run` bypasses the DSL entirely, and the issue
says the runtime should "still defensively handle bad step data submitted by
non-DSL callers" — that existing behavior stays as-is.

No new module is created. The `soma_lfe_parser` module grows new internal helpers
for the duplicate-id and from_step validation passes.

## Acceptance criteria → tests

All tests go in `apps/soma_lfe/test/soma_lfe_validation_tests.erl` (new EUnit
module). There is no runtime started for any of these tests — `soma_sup` must
remain `undefined` before and after each test, matching the pattern already
established in `soma_lfe_parse_tests` and `soma_lfe_tests`.

### Criterion 1 — duplicate step ids return `duplicate_step_id`

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → `parse_steps/2` → duplicate-id check
- Test entry: `soma_lfe:compile/2` (full chain, no layer skipped)
- Test: `test_duplicate_step_id_returns_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_validation_tests.erl`

Asserts `{error, Diags}` where at least one diagnostic has
`code => duplicate_step_id`. Does not check message text.

### Criterion 2 — forward `from_step` reference returns `invalid_from_step`

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → from_step reference check
- Test entry: `soma_lfe:compile/2`
- Test: `test_forward_from_step_returns_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_validation_tests.erl`

Uses a source where step `s2` has `(from_step s3)` and `s3` appears after `s2`.
Asserts `code => invalid_from_step`.

### Criterion 3 — unknown `from_step` reference returns `invalid_from_step`

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → from_step reference check
- Test entry: `soma_lfe:compile/2`
- Test: `test_unknown_from_step_returns_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_validation_tests.erl`

Uses a source where `(from_step ghost)` names a step id that does not exist
anywhere in the run. Asserts `code => invalid_from_step`.

### Criterion 4 — invalid `timeout_ms` returns `invalid_timeout`

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → `parse_step_children/2`
- Test entry: `soma_lfe:compile/2`
- Test: `test_invalid_timeout_returns_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_validation_tests.erl`

Covers at least two sub-cases: `timeout_ms` with value `0` and with a string
value. Asserts `code => invalid_timeout` in each.

### Criterion 5 — unknown forms return `unknown_form`

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → `parse_step_children/2`
- Test entry: `soma_lfe:compile/2`
- Test: `test_unknown_form_returns_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_validation_tests.erl`

Uses `(run (step s1 echo (frobulate)))`. Asserts `code => unknown_form`. Does not
match the message string.

### Criterion 6 — multiple diagnostics returned across steps

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → `parse_steps/2` (accumulating)
- Test entry: `soma_lfe:compile/2`
- Test: `test_multiple_diagnostics_collected` in
  `apps/soma_lfe/test/soma_lfe_validation_tests.erl`

Source has two steps with distinct errors (e.g. one with an unknown form, one
with an invalid timeout). Asserts `{error, Diags}` with `length(Diags) >= 2`.

### Criterion 7 — invalid DSL does not create a run or emit runtime events

- Call chain: none (direct assertion that `soma_sup` is not running; then
  `soma_lfe:compile/2` with invalid source; then assert `soma_sup` is still not
  running and event store has no entries for a `run_id`)
- Test entry: `soma_lfe:compile/2`
- Test: `test_invalid_dsl_does_not_start_run` in
  `apps/soma_lfe/test/soma_lfe_validation_tests.erl`

Checks `whereis(soma_sup) =:= undefined` before and after calling `compile/2`
with a source that has a `duplicate_step_id` error. This mirrors the pattern in
`soma_lfe_tests:test_compile_does_not_start_runtime/0`.

## Risks & trade-offs

**Diagnostic shape is not yet a published contract.** The `code` atom values
chosen here (`duplicate_step_id`, `invalid_from_step`, etc.) become stable once
tests depend on them. The issue says "`code` must be stable enough for tests" but
not that it is a formal public API — so adjusting a code during Dev is allowed,
but after the tests are green and merged the codes are load-bearing.

**Multi-diagnostic collection adds parser complexity.** Accumulating errors
across steps means `parse_steps` can no longer return early; it needs to separate
"I cannot even parse this step's shape" (stop, return what we have) from "I
parsed this step but found a semantic error" (record, continue). Getting that
boundary wrong can produce confusing diagnostics where a downstream error is
reported against the wrong step. The tests for criterion 6 should use inputs
where both errors are independently visible, so a mis-attribution would cause the
test to fail rather than silently pass.

**No tool-existence check.** The issue marks this optional and says it must
consult metadata only. Leaving it out keeps the compiler independent of the
registry — matching the existing `soma_lfe_tests:test_runtime_does_not_depend_on_soma_lfe`
invariant. Adding it later would require passing registry metadata into the
compiler or making the compiler call the registry, which would couple the two
apps. Not doing it now keeps that decision open.
