# [cc] agent-shell AS.2: `(explore ...)` edge form in `soma_lfe`

## Current state

`soma_lfe:compile/2` reads one constrained S-expression with
`soma_lfe_reader:read_forms/1`, then `soma_lfe:dispatch/1` selects a parser.
There is no `explore` dispatch clause today. A single `(explore ...)` form falls
through to `soma_lfe_parser:parse_run/1` and returns an
`invalid_top_level_form` diagnostic.

The repository has two step syntaxes. The compatibility `(run ...)` form uses
positional `(step Id Tool ...)` forms and `parse_step/1`. Proposal
`(run-steps ...)` uses `(step (id Id) (tool Tool) (args ...))` forms and reaches
`parse_msg_steps/2` from `parse_proposal/1`. The issue locks `explore` to this
second syntax. `parse_msg_steps/2` already preserves list order, defaults
`args` to an empty map. It delegates argument values to `parse_args/2`.
`parse_args/2` already lowers bare `(from_step Id)` to
`#{from_step => Id}` and field values such as `(bytes (from_step Id))` to
`{from_step, Id}`. The proposal-shaped step parser does not accept
`timeout_ms` today. It also permits a parsed step to omit `id` or `tool`,
leaving the later proposal normalizer to reject that map.

The `soma_lfe` application declares only `kernel` and `stdlib`. Its production
modules do not call `soma_runtime`, `soma_actor` or `soma_event_store`.
Compilation is synchronous and does not own a process or event path. Existing
tests check parts of this boundary for `(run ...)`, but there is no proof tied
to a valid `explore` form. The reader still calls `list_to_atom/1` for every
symbol. That repository-wide behavior belongs to issue #235 and cannot be
fixed or promised in this slice.

`soma_lisp:render/1` has tagged branches for result, event and message maps.
A map tagged `#{kind => explore, steps => Steps}` currently reaches the generic
map renderer, so the output is not headed by `explore`. Generic rendering also
turns `{from_step, Id}` into a quoted Erlang term. Its normal atom renderer
changes underscores to hyphens, which cannot preserve an arbitrary canonical
step id, tool name or argument key when the source reader treats symbol text
literally. A dedicated explore renderer is required for an exact term round
trip.

The contract convention is one Markdown file under `docs/contracts/` backed by
an EUnit source-file check that pins every named proof. AS.2 has no contract
file or contract check yet.

## Approach

Add a single-form `explore` clause to `soma_lfe:dispatch/1`. Route it to a new
`soma_lfe_parser:parse_explore/1` entry point. The successful result is exactly
`#{kind => explore, steps => Steps}`. Do not pass it to
`soma_proposal:normalize/1`, policy, budget, actor or runtime code in this
slice.

Extract the proposal-shaped step work into one private production named
`parse_proposal_steps/1`, with a single-step helper beneath it. Both the
`run-steps` clause in `parse_proposal/1` and `parse_explore/1` must call this
production. Leave the older positional `parse_step/1` path for `(run ...)`
unchanged. The shared proposal production accepts these fields:

- `(id Id)` with an atom id.
- `(tool Tool)` with an atom tool name.
- `(args ...)`, including the existing whole-output and field-level
  `from_step` forms.
- Optional `(timeout_ms N)` with a positive integer, lowered to the
  `timeout_ms` map key.

It returns step maps containing only the canonical fields present in the
source, plus `args => #{}` when args are omitted. It requires `id` and `tool`
before reporting success. Accumulate steps in reverse and reverse once at the
end, matching the current source-order behavior. The explore wrapper requires
at least one step. It does not add execution or policy. It also does not add
budget or reference validation.

Keep explore diagnostics separate from the older proposal and run diagnostic
wording. Return one diagnostic for the first explore-level failure. Use literal
codes and literal messages so neither the diagnostic count nor message size
depends on the rejected source:

- `(explore)` returns code `empty_explore` and message
  `<<"explore requires at least one step">>`.
- A child headed by `step` that fails the shared step production returns code
  `invalid_explore_step` and message
  `<<"explore contains a malformed step">>`.
- Any explore child not headed by `step` returns code
  `unknown_explore_form` and message
  `<<"explore accepts only step forms">>`.

Each diagnostic also carries `line => 0`, matching the current parser-level
diagnostic shape. Do not format the offending form, symbol, string or value
into these messages.

Pin the fixed messages with exact equality assertions. The malformed-step and
unknown-child cases should each include a source containing a large string
value. The returned one-element diagnostic list must be identical to the list
returned for the small form of the same error. Assert that all three codes are
different.

Add an explore-map branch to `soma_lisp:render/1` before generic map rendering.
Render the tag as the top-level head rather than as a `(kind explore)` pair.
Render each step in list order with the proposal shape:

```lisp
(explore
  (step
    (id read_file)
    (tool file_read)
    (args (path "input.txt"))
    (timeout_ms 500)))
```

The dedicated branch must preserve the exact atom spelling used in canonical
step ids, tool names and argument keys. It must also preserve argument atom
values and references. Use `atom_to_list/1` for those already-existing atoms
instead of the generic
underscore-to-hyphen conversion. Render a whole-output map as
`(args (from_step Id))`. Render a field-level tuple inside its argument pair as
`(Key (from_step Id))`. Render `timeout_ms` only when the key is present. Keep
the existing generic renderer unchanged for every non-explore term.

The renderer remains a pure term-to-iodata function in `soma_event_store`. It
must not call `soma_lfe` in production. The inverse check belongs in an umbrella
test that renders each representative canonical map. It asserts an
`(explore ...)` head, then compiles the rendered source with
`soma_lfe:compile/2`. Compare the entire resulting map for equality. Include an
empty-args step. Also include a multi-step map that carries `timeout_ms` and
both `from_step` shapes. Its ids, tools and keys should include underscores.

Add `docs/contracts/AS.2-test-contract.md`. Map every guarantee below to its
full module and test name. Add an EUnit contract check under `apps/soma_lfe/test`
that reads the file and fails when any named proof is absent.

For the compile-only proof, load the compiler before starting measurement.
Start an isolated in-memory event store as a test observer and snapshot its
events. Trace the EUnit caller for child spawns only while it compiles a valid
explore form. Assert that no spawn trace arrives. Also assert that the event
snapshot is unchanged and no runtime or actor supervisor was started.

Keep the structural checks separate from this runtime observation. Read
`soma_lfe_parser.erl` and assert that the `run-steps` branch and explore branch
both name `parse_proposal_steps/1`. Inspect `soma_lfe.app.src` for the existing
dependency list. Scan the touched production compiler and parser boundaries for
calls to `soma_runtime`, `soma_actor` or `soma_event_store`. Scan the touched
compiler, parser and renderer boundaries for atom-creation BIFs. Exclude
`soma_lfe_reader.erl` from the latter claim because its pre-existing call is
tracked by #235.

## Acceptance criteria → tests

### Criterion 1 — valid explore forms compile to canonical ordered step data and stay compile-only

- Call chain: caller → `soma_lfe:compile/2` →
  `soma_lfe_reader:read_forms/1` → `soma_lfe:dispatch/1` →
  `soma_lfe_parser:parse_explore/1` → shared
  `parse_proposal_steps/1` → argument lowering. The helper-sharing and
  dependency checks have none (direct source-file read).
- Test entry: `soma_lfe:compile/2` for output and purity behavior. The source
  guards read `soma_lfe_parser.erl`, the production app files and
  `soma_lfe.app.src` because equal output alone cannot prove one production or
  the absence of imports and atom-creation calls.
- Code boundary: `apps/soma_lfe/src/soma_lfe.erl`,
  `apps/soma_lfe/src/soma_lfe_parser.erl` and their dispatch and parsing
  functions. The dependency guard inspects `soma_lfe.app.src`, which should
  remain unchanged.
- Responsibility owner: the `soma_lfe` compile-only edge owns dispatch,
  proposal-step lowering and step order. It also owns dependency isolation.
- Test: `test_explore_compiles_canonical_steps_and_matches_run_steps` in
  `apps/soma_lfe/test/soma_lfe_explore_tests.erl`.
- Test: `test_explore_compile_starts_no_processes_or_events` in
  `apps/soma_lfe/test/soma_lfe_explore_tests.erl`.
- Test: `test_explore_and_run_steps_share_proposal_step_production` in
  `apps/soma_lfe/test/soma_lfe_explore_tests.erl`.
- Test: `test_explore_source_keeps_dependency_and_atom_creation_boundaries` in
  `apps/soma_lfe/test/soma_lfe_explore_tests.erl`.

### Criterion 2 — invalid explore forms return distinct fixed diagnostics

- Call chain: caller → `soma_lfe:compile/2` →
  `soma_lfe_reader:read_forms/1` → `soma_lfe:dispatch/1` →
  `soma_lfe_parser:parse_explore/1` → explore diagnostic selection.
- Test entry: `soma_lfe:compile/2` so reader and top-level dispatch are not
  bypassed.
- Code boundary: `soma_lfe:dispatch/1` and
  `soma_lfe_parser:parse_explore/1` in `apps/soma_lfe/src/`.
- Responsibility owner: `soma_lfe_parser` owns the bounded diagnostic returned
  at the explore edge.
- Test: `test_empty_explore_returns_fixed_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_explore_tests.erl`.
- Test: `test_malformed_explore_step_returns_fixed_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_explore_tests.erl`.
- Test: `test_unknown_explore_level_form_returns_fixed_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_explore_tests.erl`.

### Criterion 3 — canonical explore maps round-trip as `(explore ...)`

- Call chain: caller → `soma_lisp:render/1` → explore-map renderer →
  rendered source → `soma_lfe:compile/2` → reader → explore dispatch →
  shared proposal-step production.
- Test entry: `soma_lisp:render/1`, followed by the public compiler on its
  iodata converted to a binary. No render or parse layer is bypassed.
- Code boundary: `apps/soma_event_store/src/soma_lisp.erl` and the explore
  parser boundary in `apps/soma_lfe/src/`.
- Responsibility owner: `soma_lisp` owns the reversible explore serialization.
  `soma_lfe` owns its inverse source-to-map mapping.
- Test: `test_canonical_explore_maps_round_trip_through_render_and_compile` in
  `apps/soma_event_store/test/soma_lisp_explore_tests.erl`.

### Criterion 4 — AS.2 contract maps every guarantee to its proof

- Call chain: none (direct source-file read).
- Test entry: the EUnit case reads `docs/contracts/AS.2-test-contract.md`
  because the required behavior is documentation coverage.
- Code boundary: `docs/contracts/AS.2-test-contract.md` and
  `apps/soma_lfe/test/soma_as2_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the guarantee-to-test map.
- Test: `test_as2_contract_names_every_acceptance_proof` in
  `apps/soma_lfe/test/soma_as2_contract_doc_tests.erl`.

## Risks & trade-offs

- A source guard for `parse_proposal_steps/1` couples the test to a private
  helper name. Behavioral equality would allow duplicated parsers, so the
  structural check is needed for the issue's one-production guarantee.
- Fixed explore diagnostics intentionally omit the rejected form. This gives a
  constant bound and avoids reflecting large source values, but it provides
  less local detail than some older parser diagnostics. The three codes retain
  enough information to choose a repair.
- The explore renderer is an exception to the generic underscore-to-hyphen
  symbol style. Preserving literal atom spelling is necessary for exact map
  equality because the reader does not normalize arbitrary tool, id or key
  symbols back to underscore atoms.
- Recognizing `#{kind := explore, steps := Steps}` gives that tagged map a
  dedicated renderer. A noncanonical map with the same tag can still render to
  source that the compiler rejects. The round-trip promise applies only to
  canonical maps.
- Adding `timeout_ms` to the shared proposal production also makes it available
  to valid `(run-steps ...)` forms. Existing proposal forms keep their current
  output. The older `(run ...)` parser remains separate.
- The new source guard can prove that the compiler and renderer boundaries add
  no atom-conversion call. It cannot prove reader-wide atom hygiene while
  `soma_lfe_reader` retains its pre-existing `list_to_atom/1` call. Issue #235
  remains the owner of that broader change.
