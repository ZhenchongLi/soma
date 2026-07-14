### Claude

## Verdict

changes-requested

## Real issues

- The public site still says the runtime seeds only five tools. `site/src/content/docs/guides/usage.md:18` omits `text_grep` and `text_head`, while `soma_tool_registry` now seeds both. This leaves the deployed usage guide false after the Markdown manual was fixed. Update the site inventory to seven and add it to `live_builtin_docs_track_seven_tool_seed_test` so the two copies cannot drift again.

## Questions

None.

## Nits

- `apps/soma_actor/test/soma_tool_management_SUITE.erl:487` and `apps/soma_actor/test/soma_tool_management_SUITE.erl:522` still say five built-ins. The assertions use `builtin_names/0`, so only the comments are wrong.
- `apps/soma_actor/test/soma_tool_config_SUITE.erl:443` lists only the original five reserved names. The production check derives the full live seed.
- `soma_tool_tests:test_describe_has_required_keys/0` still checks only the original five modules. The manifest tests cover both readers, so this is stale duplicate coverage.

## Functional evidence

- Criterion 1 — pass: - [x] A `text_grep` step started through `soma_agent_session:start_run/2` returns `#{text => MatchingLines, match_count => ReturnedLineCount, truncated => false}` for a compilable pattern below both caps, including a zero-match pattern. Artifact: `soma_text_reader_SUITE:test_text_grep_compilable_pattern_and_zero_match` records `<<"alpha\nalphabet\n">>` with count 2 and an empty zero-match result with count 0; both carry `truncated => false`.
- Criterion 2 — pass: - [x] An invalid-regex `text_grep` run leaves bounded `{invalid_pattern, ...}` failure data on a live owning session. Artifact: `soma_text_reader_SUITE:test_text_grep_invalid_regex_fails_bounded_session_alive` checks a 4,096-byte bad pattern produces an `invalid_pattern` term no larger than 256 encoded bytes, excludes the pattern, and completes a later `echo` run on the same session.
- Criterion 3 — pass: - [x] Each text reader maps a missing required field, a non-binary required value, or a limit outside positive integers to bounded named `run.failed` data on a live owning session. Artifact: `soma_text_reader_SUITE:test_text_grep_input_validation_fails_named_session_alive` and `test_text_head_input_validation_fails_named_session_alive` cover every required field, non-binary values, zero, negative, and non-integer limits, then complete `echo` on the same session.
- Criterion 4 — pass: - [x] `text_grep` limits returned matching lines to the supplied positive `max_matches` value or 100 by default, with `truncated => true` for omitted matches. Artifact: `soma_text_reader_SUITE:test_text_grep_default_and_explicit_match_caps` returns two of three explicit matches with truncation, exactly two of two without truncation, and 100 of 101 default-capped matches with truncation.
- Criterion 5 — pass: - [x] Both text readers enforce one shared 65,536-byte `text` cap with `truncated => true` for omitted bytes. Artifact: `soma_text_reader_SUITE:test_text_readers_enforce_shared_65536_byte_cap` observes a 65,536-byte `text_grep` result containing 64 complete 1,024-byte lines and a 65,536-byte `text_head` prefix; both report truncation.
- Criterion 6 — pass: - [x] A `text_head` step started through `soma_agent_session:start_run/2` returns `#{text => PrefixThroughBoundary, truncated => HasRemainder}` for the supplied positive `lines` value or the 10-line default, including input shorter than the limit. Artifact: `soma_text_reader_SUITE:test_text_head_explicit_default_and_short_input` pins the two-line newline boundary, the ten-line default, and an unchanged shorter unterminated input with `truncated => false`.
- Criterion 7 — pass: - [x] A two-step session run produces filtered CLI stdout from `text => {from_step, StepId}` in the `text_grep` args. Artifact: `soma_text_reader_SUITE:test_text_grep_filters_cli_stdout_from_step` records three real CLI stdout lines in `cli_step` and `<<"keep alpha\nkeep gamma\n">>` with count 2 in the wired `grep_step`.
- Criterion 8 — pass: - [x] Each text-reader entry from `soma_tool_registry:catalog/0` equals its production manifest's typed `#{name, description, params}` projection, and `soma_run_resume_plan:plan/2` classifies an in-flight text reader as resumable from its live `#{adapter => erlang_module, effect => reader, idempotent => true}` descriptor (one criterion: the descriptor metadata is correct as seen by both consumers). Artifact: `soma_tool_registry_tests:text_reader_catalog_entries_equal_manifest_projections_test_` checks exact live projection equality and typed params; `soma_run_resume_plan_SUITE:test_in_flight_text_readers_resume_from_live_descriptors` checks the exact descriptor projection and `{resume, Plan}` for both readers.
- Criterion 9 — pass: - [x] A text-reader contract under `docs/contracts/` maps every acceptance guarantee to a named EUnit or Common Test case. Artifact: `docs/contracts/text-reader-test-contract.md` contains nine guarantee-to-proof rows, `soma_text_reader_contract_doc_tests:text_reader_contract_names_all_proofs_test` verifies every named proof is present, and the full gate passes at 389 EUnit and 434 Common Test cases.
