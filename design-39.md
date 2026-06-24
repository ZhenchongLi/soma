# [v0.3] Parse constrained LFE DSL without evaluation

## Current state

`apps/soma_lfe` was created in issue #38 with two public functions: `compile/2`
(source binary or string → step list) and `compile_file/2` (file path → step
list). Both are stubs. `compile/2` returns `{ok, []}` for any input.
`compile_file/2` returns `{error, [#{message => <<"file not found">>, ...}]}` if
the path does not exist, and `{ok, []}` otherwise. Neither function touches the
parser, the grammar, or any runtime process.

The existing tests in `soma_lfe_tests` cover the #38 acceptance criteria: the
app file exists, the two functions have the right return shape, and `compile/2`
does not start `soma_sup`. Those tests pass today. They say nothing about what
`compile/2` actually does with the input — which is the gap this issue fills.

## Approach

The issue asks for a parse layer, not a full compiler. The output is an internal
representation that downstream issues can turn into step maps. This issue stops
at "I can read a valid `(run ...)` form and reject malformed input with
structured diagnostics."

**Reader choice: implement a minimal reader, not the LFE system.**

The LFE system's reader (`lfe_scan`, `lfe_parse`) evaluates macros during read
and can load modules. Even in "data mode" the boundary is hard to hold without
auditing LFE internals on every OTP upgrade. A minimal reader for this grammar
is small: atoms, strings, integers, and nested lists. That is the entire token
set the DSL uses. Writing it directly in Erlang keeps the no-eval boundary
visible in code rather than a configuration flag on an external library.

The new internal module is `soma_lfe_reader`. It exposes one function:

```
soma_lfe_reader:read_forms(binary()) ->
    {ok, [term()]} | {error, [diagnostic()]}
```

where a diagnostic is `#{message => binary(), line => non_neg_integer()}`.

`compile/2` calls `soma_lfe_reader:read_forms/1`, then a new
`soma_lfe_parser:parse_run/1` that walks the raw form list and produces the
internal run representation or a diagnostic list.

The internal run representation is a plain Erlang map:

```erlang
#{
  run => #{
    steps => [
      #{id => atom(), tool => atom(), args => map(), timeout_ms => pos_integer()}
    ]
  }
}
```

`compile/2` returns `{ok, InternalRun}` or `{error, Diagnostics}`. The type
changes from `{ok, [map()]}` (a step list) to `{ok, map()}` (a run map). The
#38 tests that checked `{ok, Steps}` with `is_list(Steps)` will need updating
because the shape changes — that is expected and noted under Risks.

**What the parser accepts:**

- Exactly one top-level form. The form must be a list whose head is the atom `run`.
- Each child of `run` must be a `(step ...)` form with the shape
  `(step <id> <tool> <child-forms>...)`.
- Recognized child forms inside a step: `(args ...)` and `(timeout_ms <integer>)`.
- Inside `(args ...)`: any `(key value)` pairs are accepted, including
  `(from_step <id>)`.
- Everything else at any level produces a diagnostic instead of silently passing.

**What the parser rejects with a diagnostic:**

- Zero top-level forms.
- Two or more top-level forms.
- A top-level form whose head is not `run`.
- A child of `run` whose head is not `step`.
- A child of a step whose head is not `args` or `timeout_ms`.

The parse functions themselves start no OTP processes and call nothing in
`soma_runtime` or `soma_tools`. The `soma_lfe` app's declared dependencies
remain `[kernel, stdlib]`.

## Acceptance criteria → tests

### Criterion 1 — valid `(run ...)` form parses to an internal representation

- Call chain: none (direct call to `soma_lfe:compile/2` or `soma_lfe_reader`
  in a unit test)
- Test entry: `soma_lfe:compile/2` (the public API the issue names)
- Test: `test_valid_run_form_produces_internal_repr` in
  `apps/soma_lfe/test/soma_lfe_parse_tests.erl`

### Criterion 2 — multiple top-level forms fail with a structured diagnostic

- Call chain: none (direct call to `soma_lfe:compile/2`)
- Test entry: `soma_lfe:compile/2`
- Test: `test_multiple_top_level_forms_fail` in
  `apps/soma_lfe/test/soma_lfe_parse_tests.erl`

### Criterion 3 — a non-`run` top-level form fails with a structured diagnostic

- Call chain: none (direct call to `soma_lfe:compile/2`)
- Test entry: `soma_lfe:compile/2`
- Test: `test_non_run_top_level_form_fails` in
  `apps/soma_lfe/test/soma_lfe_parse_tests.erl`

### Criterion 4 — unknown forms inside a run or step produce structured diagnostics

- Call chain: none (direct call to `soma_lfe:compile/2`)
- Test entry: `soma_lfe:compile/2`
- Test: `test_unknown_step_child_form_fails` in
  `apps/soma_lfe/test/soma_lfe_parse_tests.erl`

### Criterion 5 — parse does not start a Soma run and does not emit runtime events

- Call chain: none (direct call to `soma_lfe:compile/2`, then check
  `whereis(soma_sup)` and query `soma_event_store`)
- Test entry: `soma_lfe:compile/2`
- Test: `test_parse_does_not_start_runtime` in
  `apps/soma_lfe/test/soma_lfe_parse_tests.erl`

## Risks & trade-offs

**`{ok, map()}` vs `{ok, [map()]}`**. The #38 stub returned `{ok, []}`, typed
as `{ok, [map()]}`. This issue changes the success shape to `{ok, map()}` where
the map holds the internal run representation. The existing #38 test
`test_compile_returns_ok_steps` asserts `is_list(Steps)` — it will fail after
this change. That test needs to be updated to match the new shape. The change is
intentional: a step list is the compiler's final output (a later issue), not the
parse layer's output.

**Minimal reader scope.** The reader handles atoms, strings (double-quoted),
integers, and nested parenthesised lists. It does not handle: floats, character
literals, LFE quoting syntax (`'`, `` ` ``, `,`), or comments. Any of those in
the source will produce a diagnostic. If a future DSL version needs them, the
reader grows then.

**Line numbers in diagnostics.** Tracking exact line numbers through a
hand-written scanner is straightforward for single-line tokens but requires
careful newline counting for multiline strings. The implementation should track
line numbers from the start; a wrong line number in a diagnostic is a usability
bug, not a correctness bug, but it will be annoying.
