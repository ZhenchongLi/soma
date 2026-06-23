# [cc] v0.2: define the tool manifest contract

## Current state

A tool's metadata today is whatever map its `describe/0` returns. Look at
`soma_tool_echo:describe/0`: it returns `#{name => echo, effect => identity,
idempotent => true, timeout_ms => 1000}`. The five built-in tools all return a
map of that same shape, but nothing in the code says they must. `soma_tool`
types the return as a bare `map()`, so the keys, the allowed values, and the
relationship between them live only in the heads of whoever wrote the tools.

`soma_tool_registry` knows even less. Its `?SEED` map is `name atom => module`
and nothing more. Every entry is assumed to be an in-BEAM module that
implements the `soma_tool` behaviour. There is no slot for a tool that runs as
an external process, and no shared schema the registry could validate a new
entry against.

v0.2 wants external one-shot CLI tools to register the same way in-BEAM tools
do. Before any code can route a tool call to either an Erlang module or a CLI
process, there has to be one written-down shape that says what a tool entry
contains and which adapter runs it. That shape is the "manifest". This issue
writes the contract down. It does not add validation or an adapter to the code.

## Approach

Add the manifest contract as a new file, `docs/tool-manifest.md`, and link it
from the README `## Docs` list. The repo already keeps its longer-form
documents this way — `docs/design.md`, `docs/release.md`, `docs/roadmap.md` are
all dedicated files reached from that list. A v0.2 contract that the README
`## Tools` section is too short to hold belongs in the same place. The
acceptance criteria allow either a README section or a `docs/` file; the
existing layout makes the `docs/` file the better fit.

The document describes the manifest as a superset of what `describe/0` returns
today, not a replacement for it. The four metadata keys in the contract —
`name`, `effect`, `idempotent`, `timeout_ms` — are exactly the keys the v0.1
tools already emit. The new part is the adapter: a manifest names which of two
adapters runs the tool. `erlang_module` runs an in-BEAM module that implements
the `soma_tool` behaviour, which is every v0.1 tool. `cli` runs an external
one-shot executable. The five v0.1 tools map onto `erlang_module` unchanged, so
the contract is additive and the out-of-scope rule against rewriting
`describe/0` holds.

The CLI adapter schema carries an executable and a separate argv list, never a
shell command string. This is not a new rule. The README and CLAUDE.md already
state that external tools use executable plus args and never shell strings; the
manifest contract writes that rule into the schema so a `cli` entry cannot
express a shell string in the first place.

Because this is a documentation-only issue, each "test" is a content check
against `docs/tool-manifest.md` — a grep-style assertion that a required
heading, key, value, adapter name, example, or non-goal is present in the file.
There is no Erlang code under test, so every criterion below uses the
`none (direct source-file read)` call-chain label. The test reads the doc file
directly and asserts on its text.

## Acceptance criteria → tests

### Criterion 1 — a discoverable manifest-contract heading exists
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert a top-level heading names the v0.2 tool manifest contract
- Test: `test_manifest_doc_has_heading` (grep the file for the contract heading)

### Criterion 2 — the four required metadata keys are listed and explained
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert each of `name`, `effect`, `idempotent`, `timeout_ms` appears with a description of what it means
- Test: `test_manifest_doc_lists_four_keys` (grep for all four key names plus their meanings)

### Criterion 3 — the allowed `effect` values are recorded
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert `identity`, `reader`, `state` are named as the allowed values of `effect`
- Test: `test_manifest_doc_lists_effect_values` (grep for the three effect values)

### Criterion 4 — exactly two adapter types are defined with what each runs
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert `erlang_module` and `cli` are the two adapter types, each with a line saying what it runs
- Test: `test_manifest_doc_defines_two_adapters` (grep for both adapter names and their run descriptions)

### Criterion 5 — the CLI adapter schema is executable plus argv, never a shell string
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert the `cli` schema specifies an executable and a separate argv list, and states a shell command string is never valid
- Test: `test_manifest_doc_cli_schema_no_shell` (grep for the executable + argv split and the no-shell-string rule)

### Criterion 6 — the five v0.1 tools stay valid and map onto `erlang_module`
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert `echo`, `sleep`, `fail`, `file_read`, `file_write` are stated to remain valid under the contract via the `erlang_module` adapter
- Test: `test_manifest_doc_v01_tools_map_to_erlang_module` (grep for all five tool names tied to `erlang_module`)

### Criterion 7 — at least one valid manifest example
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert at least one example is marked as a valid manifest
- Test: `test_manifest_doc_has_valid_example` (grep for a labelled valid example)

### Criterion 8 — at least one invalid manifest example with a reason
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert at least one example is marked invalid and carries a note on why it is rejected
- Test: `test_manifest_doc_has_invalid_example` (grep for a labelled invalid example plus its rejection reason)

### Criterion 9 — the v0.2 non-goals are listed
- Call chain: none (direct source-file read)
- Test entry: read `docs/tool-manifest.md` and assert it lists the non-goals — no MCP adapter, no LLM planner, no LFE DSL, no DAG execution, no long-running port pool, no OS sandbox beyond the adapter safety rules here
- Test: `test_manifest_doc_lists_non_goals` (grep for all six non-goals)

## Risks & trade-offs

The contract is written down but not enforced. Nothing in `soma_tool_registry`
or the runtime checks a manifest against it, so a tool entry that violates the
contract still compiles and runs today. That gap is intended — validation is a
later v0.2 issue — but it means the doc and the code can drift until that issue
lands. The invalid-example section is the only guard against drift in the
meantime, and it only helps a reader who actually opens the file.

Putting the contract in `docs/tool-manifest.md` rather than the README
`## Tools` section means the README still describes only the v0.1 tool shape.
A reader who stops at the README will not see the manifest unless they follow
the `## Docs` link. Adding the link to the `## Docs` list is the mitigation, but
a one-line pointer is easy to miss compared to inline prose.

The manifest is presented as a superset of `describe/0`, which leaves two
overlapping descriptions of the same metadata — the `soma_tool` behaviour in
code and the manifest in the doc. Keeping `describe/0` untouched is the right
call for this issue, but the next issue that adds validation will have to decide
which of the two is the source of truth, and that decision is deferred here.
