## Current state

Soma already has the execution seams this slice needs. A call through
`soma_agent_session:start_run/2` starts `soma_run`, resolves a normalized tool
descriptor from the live `soma_tool_registry`, and invokes the backing module in
its own `soma_tool_call` process. A tool's `{error, Reason}` return becomes the
existing `tool.failed -> step.failed -> run.failed` trail and a failed session
status; the owning session stays alive. `soma_run:resolve_args/2` also already
supports field-level wiring such as `text => {from_step, StepId}`, and CLI stdout
is already a binary step output. No runtime, actor, Lisp, or CLI production
change is needed for the requested composition.

Built-in tools own their production metadata in `manifest/0`. The registry's
`?BUILTIN_MODULES` seed currently contains `echo`, `sleep`, `fail`, `file_read`,
and `file_write`; it normalizes those manifests once at boot. `catalog/0`
constructs exactly `#{name, description, params}` from each live descriptor,
while `soma_run_resume_plan:plan/2` independently reads the same live
descriptor's `effect` and `idempotent` fields to decide whether an in-flight
step is safe to repeat. Adding the two modules to that one seed therefore feeds
execution, the model-facing catalog, reserved built-in names, and resume safety
without adding a parallel registry path.

There is no built-in text reader or shared text-output cap today. The only
65,536-byte constant is the CLI adapter's separate stdout-buffer limit in
`soma_tool_call`; it has different failure semantics and lives in
`soma_runtime`, so this slice should not move or reuse it. Several tests and
docs also assume that the registry contains exactly the original five
built-ins; those exact-set assertions will need to recognize the two new
entries even though actor and CLI production code remain unchanged.

## Approach

Add `soma_tool_text_grep` and `soma_tool_text_head` under `apps/soma_tools/src`.
Each implements `soma_tool`, exports `describe/0`, `manifest/0`, and `invoke/2`,
and declares the locked live metadata
`#{adapter => erlang_module, effect => reader, idempotent => true}` (with the
same small positive built-in timeout used by the existing in-BEAM readers).
Their manifests carry non-empty descriptions and these typed params:

- `text_grep`: required string `text`, required string `pattern`, optional
  integer `max_matches` (default 100).
- `text_head`: required string `text`, optional integer `lines` (default 10).

Add both modules to `soma_tool_registry`'s built-in module list. Do not add a
second manifest literal or special dispatch branch: normalization, registry
resolution, catalog projection, config-name reservation, the tool-call worker,
and resume classification must continue to consume the production manifests.

Put line traversal and the single text-output ceiling in a small internal
`soma_tool_text` helper in `soma_tools`. It owns the one
`65_536`-byte constant and byte-prefix/line-chunk helpers used by both readers;
the CLI adapter keeps its independent runtime limit. Work on binaries and build
results as iolists before one final conversion so repeated line appends are not
quadratic. A line is the bytes through the next `\n`; matching is performed on
the line body without that delimiter, while returned text preserves the
original delimiter. A non-empty final segment without `\n` is one line, an
ending `\n` does not create a phantom extra line, and empty input has zero
lines. Do not normalize `\r\n`, interpret Unicode characters, or add regex
flags in this slice.

`text_grep` validates its map input, required binary fields, and positive
integer limit before compiling the binary pattern once with `re:compile/1`.
It scans logical lines in source order and runs the compiled pattern with no
captures. A returned matching line is always complete, including its original
terminating `\n` when present. Stop before the first match that would exceed
either `max_matches` or the shared byte cap; do not skip that match and include
later ones. `match_count` is exactly the number of complete lines appended.
`truncated` is true only when at least one matching line was omitted by either
cap, not merely because non-matching source text remains. Thus zero matches
returns `#{text => <<>>, match_count => 0, truncated => false}`, an exact cap
with no later match is not truncated, and a single matching line larger than
the byte cap is omitted whole with `match_count => 0` and `truncated => true`.

`text_head` locates the end of the requested/default number of logical lines,
or EOF when the input is shorter, then applies the shared byte-prefix cap. It
returns `#{text => Prefix, truncated => HasRemainder}`, where `HasRemainder` is
true if either the line limit or byte limit omitted at least one source byte.
Below the byte cap, `Prefix` ends through the selected `\n` boundary when one
exists; if one selected line itself crosses 65,536 bytes, the hard output cap
may end inside that line. Empty and shorter-than-limit inputs return all their
bytes with `truncated => false`.

Validation failures return named data from `invoke/2`; they do not raise and do
not include the offending text, pattern, or limit value. Use stable bounded
shapes such as `{missing_field, Field}`, `{invalid_field_type, Field, binary}`,
and `{invalid_limit, Field, positive_integer}`. Normalize a regex compilation
failure to `{invalid_pattern, Detail}`, where `Detail` contains at most the
compile offset and a short capped diagnostic, never the pattern. The existing
tool worker and run failure path then record that reason and keep the session
responsive. A non-map input should likewise become bounded invalid-input data
rather than a function-clause crash.

Add one Common Test suite, `soma_text_reader_SUITE`, for the session-level
contract. Read successful outputs from the named step's `step.succeeded`
payload after `run.completed`; for every invalid-input run, assert the exact
reason class in `run.failed`, the failed session status, and that the same
session remains responsive and can complete a later `echo` run. Its CLI fixture
should be a directly launched executable that prints fixed multiline stdout;
the test's second step passes that binary through
`text => {from_step, cli_step}`. No pipeline or `sh -c` is introduced.

Extend the registry EUnit coverage with an equality check between each live
text-reader catalog entry and `maps:with([name, description, params],
Module:manifest())`. Extend `soma_run_resume_plan_SUITE` with an in-flight trail
for each text reader; in the same case, assert the live descriptor projection
is exactly `#{adapter => erlang_module, effect => reader, idempotent => true}`
before expecting a resume verdict. Also extend the existing production-manifest
module lists and exact built-in catalog/config/planning fixtures from five to
seven so the full gate reflects the intentional seed change.

Create `docs/contracts/text-reader-test-contract.md` with every guarantee below
mapped to its named EUnit or Common Test proof, plus a small
`soma_text_reader_contract_doc_tests` EUnit pin that checks the mapping names.
Update the built-in inventories in `README.md`, `docs/design.md`, and
`docs/tool-manifest.md`; update the existing tool-catalog contract if its
seeded-catalog proof is renamed. Historical wording about the five v0.1 tools
may stay explicitly historical, but no current inventory should claim that the
live registry contains only five tools.

## Acceptance criteria → tests

| Acceptance guarantee | Named proof |
| --- | --- |
| A session-run `text_grep` returns the locked structured output for matches below both caps and for zero matches. | `soma_text_reader_SUITE:test_text_grep_compilable_pattern_and_zero_match` |
| An invalid regular expression becomes bounded `{invalid_pattern, ...}` run failure data and the session stays usable. | `soma_text_reader_SUITE:test_text_grep_invalid_regex_fails_bounded_session_alive` |
| Missing required fields, non-binary required values, and non-positive/non-integer limits fail boundedly for both readers while the owning session survives. | `soma_text_reader_SUITE:test_text_grep_input_validation_fails_named_session_alive`; `soma_text_reader_SUITE:test_text_head_input_validation_fails_named_session_alive` |
| `text_grep` enforces explicit `max_matches` and the default of 100, with `truncated` true exactly when a matching line is omitted. | `soma_text_reader_SUITE:test_text_grep_default_and_explicit_match_caps` |
| Both readers enforce the one 65,536-byte text-output cap and report omitted bytes/matching lines through `truncated`. | `soma_text_reader_SUITE:test_text_readers_enforce_shared_65536_byte_cap` |
| `text_head` implements explicit/default line limits, newline boundaries, final unterminated lines, and shorter-than-limit input. | `soma_text_reader_SUITE:test_text_head_explicit_default_and_short_input` |
| A two-step session run filters real CLI stdout through field-level `text => {from_step, StepId}`. | `soma_text_reader_SUITE:test_text_grep_filters_cli_stdout_from_step` |
| Catalog entries equal the typed production-manifest projections, and both in-flight tools are resumable from their live reader/idempotent Erlang descriptors. | `soma_tool_registry_tests:text_reader_catalog_entries_equal_manifest_projections_test_`; `soma_run_resume_plan_SUITE:test_in_flight_text_readers_resume_from_live_descriptors` |
| A contract under `docs/contracts/` maps every acceptance guarantee to named proofs. | `soma_text_reader_contract_doc_tests:text_reader_contract_names_all_proofs_test` |

## Risks & trade-offs

- Regex behavior is deliberately the Erlang `re` engine's default byte-oriented
  behavior. Unicode modes, case flags, multiline flags, and streaming matching
  remain out of scope; documenting and testing line-delimiter behavior avoids
  accidentally implying GNU `grep` option compatibility.
- The two truncation dimensions differ by tool. `text_grep` must preserve
  complete matching lines, so an oversized first match can yield an empty text
  result; `text_head` is a byte prefix after its line selection and may end
  inside a long line. Keeping those rules explicit prevents `match_count` from
  counting a partial line while still honoring the hard cap for `text_head`.
- Determining whether `text_grep` is truncated at an exact match limit requires
  inspecting later lines until another match is found. The implementation may
  stop at that first omitted match, but cannot set `truncated => true` merely
  because it returned exactly the limit.
- The cap bounds only each tool's returned `text` field. The runtime already
  journals submitted step args in `run.started`, and input-size limits or
  streaming are not part of this issue; do not widen the slice into changes to
  `soma_run` or durable event semantics.
- Adding built-ins changes every live `builtin_names/0` consumer, including
  config-name reservation and all-policy planning catalogs. That is intended,
  but exact five-name fixtures must be updated together or unrelated actor/tool
  tests will fail despite correct reader behavior.
