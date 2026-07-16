# [cc] parser hardening: no atom creation from external Lisp and config input

## Current state

`soma_lfe_reader:read_forms/1` calls `read_forms/2` with `create_atoms`.
`soma_lfe:compile/2` also selects `create_atoms` unless the caller passes
`#{existing_atoms_only => true}`. The service socket and delegate model path pass
that option today. CLI requests and actor Lisp still take the atom-creating
default. Task files, tool files and direct compiler callers do too.

The safe reader mode already represents a fresh spelling as
`{external_symbol, Binary}`. Parser support for that term is incomplete. Invoke
and proposal steps accept it in some identifier positions. The older run and
task productions still require atoms for step ids and tool names. Task binding
names must also be atoms. Several unknown-form branches render the rejected term into the
diagnostic. Their output size therefore follows the external symbol size.

`soma_config` keeps TOML keys as strings while parsing. `carry_optional/3` then
uses `list_to_atom/1` for keys selected from a fixed list. The output keys are a
closed vocabulary, but the production path still contains an atom-creation BIF.

`soma_tool_config` reads a tool name as a binary string and calls
`binary_to_atom/2` in `build_manifest/1`. The manifest and registry types assume
every name is an atom. `soma_cli:daemon/1` runs this loader after the runtime
registry starts and before either socket listener starts. A fresh tool file can
therefore intern its name in the long-lived daemon during every cold boot.

Existing tests pin individual compile shapes and several renderer round trips.
There is no single compatibility fixture for changing the reader default. There
is also no parser-hardening contract that ties the Lisp and TOML guarantees to
the config-tool guarantee.

## Approach

Make safe symbol handling the public production default. `read_forms/1` must use
the existing-atoms-only scanner behavior. `soma_lfe:compile/2` must ensure the
fixed parser vocabulary is loaded before scanning, then select the same safe
behavior without requiring an option. Keep accepting the current
`existing_atoms_only` option so service and delegate callers need no coordinated
change. No external compile option may switch atom creation back on.

Keep `{external_symbol, Binary}` as the reader's distinction between an
unquoted symbol and a quoted string. At each parser position, classify the term
by grammar role. A fresh caller identifier or value becomes its binary spelling.
A fresh grammar head is rejected. Established symbols that already map to the
current atoms keep their current map representation. This preserves the public
maps for the fixed vocabulary while allowing caller data to stay bounded. This
includes a new step id, tool name, argument key, argument value, task binding or
reference. Identifier
validation must compare spellings so an atom spelling and its binary form still
match for duplicate checks and `from_step` references.

Add fixed parser errors for `{external_symbol, _}` at top-level and nested
grammar-head boundaries. Reuse the named diagnostic code owned by that boundary.
Use a constant binary message and do not include the rejected spelling or raw
form. Unknown short and long symbols must return the same diagnostic term.

Replace `soma_config` key conversion with an allowlist that stores both forms of
each option, such as `{"max_tokens", max_tokens}`. TOML lookup uses the text
entry. Map construction uses the literal atom entry. Provider selection remains
the existing binary pattern match to `openai_compat`.

Keep config tool names as binaries from `compile_tool/1` through manifest
normalization and registry storage. Validate the decoded name before
registration. A name of at most 255 Unicode characters is valid. A longer name
returns `{invalid_tool_name, too_long}` without copying the name into the error.
Built-in manifests keep their atom names. Broaden the manifest and registry name
contract to `atom() | binary()`. Reserved-name and duplicate checks must compare
the binary spelling so a binary `<<"echo">>` cannot shadow the atom `echo`.
Only make direct name consumers total for the widened type. Use one pure
atom-or-binary spelling helper for formatting and persistence names. Use the
same helper for registry comparisons. Do not add a Lisp form or change request
dispatch.

Add `docs/contracts/parser-hardening-test-contract.md`. Give each guarantee one
row with the exact module and test name below. Add a source-file test that fails
when any row or proving case is missing.

## Acceptance criteria → tests

### Criterion 1 — external Lisp symbols do not grow the atom table

- Call chain: External source → `soma_lfe_reader:read_forms/1` for the direct
  reader case. External source → `soma_lfe:compile/2` →
  `soma_lfe_reader:read_forms/2` → `soma_lfe_parser` for accepted and rejected
  compiler cases.
- Test entry: `soma_lfe_reader:read_forms/1` and `soma_lfe:compile/2`. The table starts at both public boundaries named by the criterion.
- Code boundary: `apps/soma_lfe/src/soma_lfe_reader.erl` and
  `apps/soma_lfe/src/soma_lfe.erl`. Identifier-position clauses in
  `apps/soma_lfe/src/soma_lfe_parser.erl` are also in scope.
- Responsibility owner: `soma_lfe` owns conversion of external Lisp text into bounded Erlang data.
- Test: `test_external_lisp_symbols_have_zero_atom_count_delta` in `apps/soma_lfe/test/soma_lfe_parser_hardening_tests.erl`.

The table must warm the fixed modules before sampling. It must generate every
fresh spelling after warm-up without converting it to an atom. Include a direct
reader spelling plus an accepted run or task with fresh caller identifiers.
Include a rejected form with a fresh grammar head. Assert the exact accepted binary fields
or the named error before checking the atom count is unchanged for every row.

### Criterion 2 — established compile maps and Lisp wire round trips stay compatible

- Call chain: CLI Lisp, task Lisp, actor Lisp or model Lisp →
  `soma_lfe:compile/2` → reader → parser → current map. A canonical wire map
  follows `soma_lisp:render/1` → `soma_lfe:compile/2` → the same map.
- Test entry: `soma_lfe:compile/2` and `soma_lisp:render/1`. Socket transport
  is skipped because it does not own the source-to-map or map-to-source
  contract.
- Code boundary: `apps/soma_lfe/src/soma_lfe.erl` and
  `apps/soma_lfe/src/soma_lfe_parser.erl`. The inverse renderer in
  `apps/soma_event_store/src/soma_lisp.erl` is also in scope.
- Responsibility owner: `soma_lfe` and `soma_lisp` jointly own the codec consumed by the CLI wire and other Lisp edges.
- Test: `test_safe_reader_default_preserves_compile_maps_and_wire_round_trips`
  in `apps/soma_actor/test/soma_parser_hardening_compat_tests.erl`.

Use one fixture table for the established `run`, `task` and `msg` heads. Include
proposal, invoke, explore and CLI command heads. Copy the expected maps from the current
public tests so atom keys and established atom identifiers remain pinned. Add
canonical message, invoke and explore maps to a second table. Assert
`compile(render(Map), #{})` returns the identical map for every renderable wire
shape.

### Criterion 3 — unknown grammar symbols have fixed named diagnostics

- Call chain: External Lisp with an unknown grammar head →
  `soma_lfe:compile/2` → safe reader token → parser grammar boundary →
  `{error, [Diagnostic]}`.
- Test entry: `soma_lfe:compile/2`. This keeps the reader and parser classification in the proof.
- Code boundary: dispatch and unknown-head clauses in `apps/soma_lfe/src/soma_lfe.erl` and `apps/soma_lfe/src/soma_lfe_parser.erl`.
- Responsibility owner: `soma_lfe_parser` owns bounded grammar diagnostics after tokenization.
- Test: `test_unknown_grammar_symbols_have_fixed_named_diagnostics` in `apps/soma_lfe/test/soma_lfe_parser_hardening_tests.erl`.

Build paired short and 255-character fresh heads for a representative top-level
position. Add run-child and step-child pairs. Assert each pair returns byte-identical
diagnostics. Each diagnostic must have a fixed atom `code`, a fixed binary
`message` plus a line field. The rejected spelling must not appear in the
diagnostic.

### Criterion 4 — the TOML-key production path contains no atom-creation BIF

- Call chain: none (compile-time assertion).
- Test entry: Direct source-file read of
  `apps/soma_actor/src/soma_config.erl`. Runtime value tests cannot prove that a
  dormant atom-creation call is absent.
- Code boundary: the option allowlist and `carry_optional` path in `apps/soma_actor/src/soma_config.erl`.
- Responsibility owner: `soma_config` owns translation from parsed TOML text keys to the fixed model-config key vocabulary.
- Test: `test_toml_key_path_has_no_atom_creation_bif` in `apps/soma_actor/test/soma_config_tests.erl`.

The source assertion must reject `list_to_atom/1` and `binary_to_atom/2` in the
production module. Existing value tests continue to prove that allowed optional
keys land under the same literal atom keys.

### Criterion 5 — daemon boot keeps config tool names binary and atom-safe

- Call chain: `soma_cli:daemon/1` → `daemon_with_config/3` →
  `soma_tool_config:load_dir/1` → reader → tool compiler →
  `soma_tool_registry:register_tool/1` →
  `soma_tool_manifest:normalize/1` → binary-keyed registry state.
- Test entry: `soma_cli:daemon/1`. No boot or registry layer is bypassed.
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` plus name validation
  in `apps/soma_tools/src/soma_tool_manifest.erl`. Name key types in
  `apps/soma_tools/src/soma_tool_registry.erl` are also in scope. Direct
  atom-only name consumers may be adjusted to preserve their current behavior.
- Responsibility owner: The config-tool loader owns external name admission. The manifest and registry own the accepted identity contract.
- Test: `test_daemon_boot_config_tool_names_are_binary_and_atom_safe` in `apps/soma_actor/test/soma_tool_config_SUITE.erl`.

Warm and stop the same daemon path before creating the unique names. The test
table then supplies one valid fresh name and one name longer than 255
characters. Boot once with both files. Resolve the valid descriptor with the
fresh binary and assert its `name` is that binary. Capture the loader's existing
skip warning for the long file and assert its reason is exactly
`{invalid_tool_name, too_long}`. The atom count sampled immediately before this
boot must equal the count after both assertions. The daemon must still answer a
ping.

### Criterion 6 — the parser-hardening contract maps every guarantee

- Call chain: none (direct source-file read).
- Test entry: `docs/contracts/parser-hardening-test-contract.md`.
- Code boundary: `docs/contracts/parser-hardening-test-contract.md` and its doc-drift test only.
- Responsibility owner: `docs/contracts/` owns the guarantee-to-proof index.
- Test: `test_parser_hardening_contract_maps_every_guarantee` in `apps/soma_actor/test/soma_parser_hardening_contract_tests.erl`.

The contract must name all five behavior tests above and its own doc-drift test.
The test must assert that every criterion heading and fully qualified proving
case appears exactly once.

## Risks & trade-offs

Atom count is VM-global. Module loading or unrelated background work can make a
correct test noisy. Warm the exact production path first. Generate unique
spellings only after warm-up. Keep each measurement and assertion in one serial
test process.

The safe reader can return an atom for an established spelling and a binary for
a fresh spelling. That split is required to preserve current compile maps. All
identifier equality checks must compare spelling where a reference can cross
the two representations.

Binary config-tool names widen a registry contract that many callers currently
treat as atom-only. A missed formatter or comparison can cause a later crash
even when boot succeeds. Limit the audit to direct name consumers and route
their conversion through one total helper. Keep built-in names as atoms so
existing module manifests and runtime descriptors do not churn.

The 255 limit is defined in Unicode characters, not UTF-8 bytes. Validation must
decode the binary before counting. Invalid text must fail with a separate fixed
name error rather than reaching filesystem or registry code.

Fixed diagnostics no longer echo an unknown symbol. This reduces detail in the
message, but keeps errors bounded and prevents attacker-controlled text from
becoming durable diagnostic payload. The line field still identifies the source
location.
