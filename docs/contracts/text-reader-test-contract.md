# Text Reader Test Contract

This contract maps the acceptance guarantees for the built-in `text_grep` and
`text_head` readers to their named EUnit or Common Test proofs.

| Acceptance guarantee | Named proof |
| --- | --- |
| A session-run `text_grep` returns the specified structured output for matches below both caps and for zero matches. | `soma_text_reader_SUITE:test_text_grep_compilable_pattern_and_zero_match` |
| An invalid regular expression becomes bounded `{invalid_pattern, ...}` run-failure data and the session stays usable. | `soma_text_reader_SUITE:test_text_grep_invalid_regex_fails_bounded_session_alive` |
| Missing required fields, non-binary required values, and non-positive or non-integer limits fail boundedly for both readers while the owning session survives. | `soma_text_reader_SUITE:test_text_grep_input_validation_fails_named_session_alive`; `soma_text_reader_SUITE:test_text_head_input_validation_fails_named_session_alive` |
| `text_grep` enforces explicit `max_matches` and the default of 100, with `truncated` true exactly when a matching line is omitted. | `soma_text_reader_SUITE:test_text_grep_default_and_explicit_match_caps` |
| Both readers enforce the shared 65,536-byte text-output cap and report omitted bytes or matching lines through `truncated`. | `soma_text_reader_SUITE:test_text_readers_enforce_shared_65536_byte_cap` |
| `text_head` implements explicit and default line limits, newline boundaries, final unterminated lines, and shorter-than-limit input. | `soma_text_reader_SUITE:test_text_head_explicit_default_and_short_input` |
| A two-step session run filters real CLI stdout through field-level `text => {from_step, StepId}` wiring. | `soma_text_reader_SUITE:test_text_grep_filters_cli_stdout_from_step` |
| Catalog entries equal the typed production-manifest projections, and both in-flight tools are resumable from their live reader/idempotent Erlang descriptors. | `soma_tool_registry_tests:text_reader_catalog_entries_equal_manifest_projections_test_`; `soma_run_resume_plan_SUITE:test_in_flight_text_readers_resume_from_live_descriptors` |
| This contract maps every acceptance guarantee to its named proof. | `soma_text_reader_contract_doc_tests:text_reader_contract_names_all_proofs_test` |
