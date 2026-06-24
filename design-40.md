# [v0.3] Compile DSL forms to Soma step maps

## Current state

`soma_lfe_reader` tokenises and parses parenthesised source into raw Erlang
terms. `soma_lfe_parser` walks those terms and produces an internal run map
`#{run => #{steps => [...]}}`. `soma_lfe.erl` is the public boundary that
threads both together.

Two things in `soma_lfe_parser` do not yet match what the runtime expects:

1. `parse_step_children` fills in `timeout_ms => 5000` when the DSL form omits
   a `(timeout_ms N)` clause. The runtime checks `maps:get(timeout_ms, Step,
   undefined)` and skips the per-step timer when the key is absent, so
   defaulting to 5000 is wrong — it arms a timer the author never asked for.

2. `coerce_value` leaves a nested list like `[from_step, read]` as a plain
   Erlang list. The runtime's `resolve_args` branches on two shapes:
   `#{from_step => Id}` (bare — the whole args map is replaced by a prior
   step's output) and `{from_step, Id}` (field-level — one arg value comes
   from a prior step). Neither shape is a list. `parse_args` also has no
   clause for a bare `(from_step Id)` form, so it would hit the catch-all
   error path.

No changes are needed in `soma_run`, `soma_agent_session`, or any tool module.
The existing step-map contract — `#{id, tool, args, timeout_ms?}` — is already
right; the compiler just needs to emit it correctly.

## Approach

All work goes in `soma_lfe_parser.erl`. No new modules, no new files.

**Drop the default `timeout_ms`.** Change the initial accumulator in
`parse_step_children` from `#{args => #{}, timeout_ms => 5000}` to
`#{args => #{}}`. The key only appears in the emitted step map when the DSL
form includes `(timeout_ms N)`.

**Bare `from_step` in args.** When `(args (from_step Id))` appears — the
`(args ...)` child list contains exactly one element, `[from_step, Id]` — emit
`#{from_step => Id}` as the step's args map. This is the shape `resolve_args`
matches on its first clause. Add a dedicated clause to `parse_args` for this
case before the general key-value loop.

**Field-level `from_step`.** When `(Key (from_step Id))` appears — a two-element
arg pair where the value is `[from_step, Id]` — emit `Key => {from_step, Id}`.
Extend `coerce_value` to match `[from_step, Id]` and return `{from_step, Id}`.
The general `[[Key, Value] | Rest]` clause in `parse_args` already calls
`coerce_value(Value)`, so coercing the right shape there is enough.

**String/binary normalization.** The reader already returns double-quoted
strings as binaries (via `list_to_binary`). Atoms stay as atoms. Integers stay
as integers. No extra normalization is needed in the parser; the built-in tools
accept binaries for string fields like `path` and `root`, and atoms for step
IDs and tool names, which is exactly what falls out.

**Output shape.** After the two fixes, `soma_lfe:compile/2` returns
`{ok, #{run => #{steps => Steps}}}` where `Steps` is a list the caller passes
to `soma_agent_session:start_run/2` as:

```erlang
{ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
soma_agent_session:start_run(SessionPid, Steps).
```

The caller extracts `Steps` from the returned map. `start_run/2` takes a plain
list, so one `maps:get` is all the glue needed.

## Acceptance criteria → tests

All tests go in `apps/soma_lfe/test/soma_lfe_compile_tests.erl` (new EUnit
module). The module follows the same `test_<name>/0` + `<name>_test/0`
convention used in `soma_lfe_parse_tests.erl`.

### Criterion 1 — three-step demo compiles to the expected list of maps

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1`
- Test entry: `soma_lfe:compile/2` (full chain, no layer skipped)
- Test: `test_three_step_demo_compiles` in
  `apps/soma_lfe/test/soma_lfe_compile_tests.erl`

### Criterion 2 — bare `from_step` and field-level `from_step` compile to the runtime's reference shapes

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → `parse_args/2` → `coerce_value/1`
- Test entry: `soma_lfe:compile/2` (full chain, no layer skipped)
- Test: `test_from_step_shapes_compile` in
  `apps/soma_lfe/test/soma_lfe_compile_tests.erl`

### Criterion 3 — missing optional `timeout_ms` is omitted from the emitted step map

- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe_parser:parse_run/1` → `parse_step_children/2`
- Test entry: `soma_lfe:compile/2` (full chain, no layer skipped)
- Test: `test_timeout_ms_omitted_when_absent` in
  `apps/soma_lfe/test/soma_lfe_compile_tests.erl`

### Criterion 4 — compiler output can be passed directly to `soma_agent_session:start_run/2`

- Call chain: none (this is a type/shape assertion, not a runtime execution test;
  starting the supervision tree is out of scope for the compiler issue)
- Test entry: `soma_lfe:compile/2` only — the test asserts the extracted
  `Steps` list satisfies the structural precondition `soma_agent_session:start_run/2`
  requires (`is_list(Steps)` and each element `is_map`), without booting the
  runtime
- Test: `test_output_satisfies_start_run_contract` in
  `apps/soma_lfe/test/soma_lfe_compile_tests.erl`

### Criterion 5 — tests assert exact output maps for representative examples

This criterion is satisfied by the assertions inside `test_three_step_demo_compiles`
and `test_from_step_shapes_compile` — both use `?assertEqual` on the full expected
map, not just structural checks. No separate test function is needed.

## Risks & trade-offs

**`timeout_ms` default removal is a breaking change for existing callers that
relied on the implicit 5000.** Any call site that passed DSL source without
`(timeout_ms N)` and expected a 5000ms timer will now get an unbounded wait
instead. There are no callers in the repo today beyond the EUnit tests (which
will be updated), so the breakage is contained. The change is correct: the
runtime already handles the absent key as "no timer".

**Bare `from_step` is only valid as the sole entry in `(args ...)`.** The
current plan adds a special clause for `[[from_step, Id]]` (a single-element
list). If the author writes `(args (from_step read) (extra foo))`, the parser
needs to reject it with a diagnostic rather than silently dropping `(extra foo)`.
The clause ordering should be: bare `from_step` first (single-element match),
then the general key-value loop. A two-or-more element list that starts with
`[from_step, _]` should fall through to the existing catch-all error.

**`coerce_value([from_step, Id])` matches on a two-element list.** Any list
value that happens to start with the atom `from_step` will be coerced to a
tuple, which is the right shape — but it also means `coerce_value` is no longer
a pure pass-through for arbitrary lists. The DSL is constrained enough that no
other list value should appear, but this is worth documenting in the module
comment.
