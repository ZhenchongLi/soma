-module(soma_text_reader_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/text-reader-test-contract.md").

text_reader_contract_names_all_proofs_test() ->
    {ok, Doc} = file:read_file(?DOC_PATH),
    Proofs =
        [<<"soma_text_reader_SUITE:test_text_grep_compilable_pattern_and_zero_match">>,
         <<"soma_text_reader_SUITE:test_text_grep_invalid_regex_fails_bounded_session_alive">>,
         <<"soma_text_reader_SUITE:test_text_grep_input_validation_fails_named_session_alive">>,
         <<"soma_text_reader_SUITE:test_text_head_input_validation_fails_named_session_alive">>,
         <<"soma_text_reader_SUITE:test_text_grep_default_and_explicit_match_caps">>,
         <<"soma_text_reader_SUITE:test_text_readers_enforce_shared_65536_byte_cap">>,
         <<"soma_text_reader_SUITE:test_text_head_explicit_default_and_short_input">>,
         <<"soma_text_reader_SUITE:test_text_grep_filters_cli_stdout_from_step">>,
         <<"soma_tool_registry_tests:text_reader_catalog_entries_equal_manifest_projections_test_">>,
         <<"soma_run_resume_plan_SUITE:test_in_flight_text_readers_resume_from_live_descriptors">>,
         <<"soma_text_reader_contract_doc_tests:text_reader_contract_names_all_proofs_test">>],
    Missing = [Proof || Proof <- Proofs,
                        binary:match(Doc, Proof) =:= nomatch],
    ?assertEqual([], Missing).

live_builtin_docs_track_seven_tool_seed_test() ->
    Expectations =
        [{"README.md", [<<"`text_grep`">>, <<"`text_head`">>]},
         {"docs/design.md", [<<"`text_grep`">>, <<"`text_head`">>]},
         {"docs/tool-manifest.md",
          [<<"seven built-in tools">>,
           <<"| `text_grep` |">>,
           <<"| `text_head` |">>]},
         {"docs/usage.md",
          [<<"| `text_grep` |">>,
           <<"| `text_head` |">>,
           <<"`file_write`, `text_grep`, `text_head`)">>]},
         {"site/src/content/docs/guides/usage.md",
          [<<"seven built-in">>, <<"`text_grep`">>, <<"`text_head`">>]},
         {"docs/roadmap.md", [<<"the seven built-ins declare descriptions">>]},
         {"examples/cli-demo/README.md",
          [<<"All seven built-in tools">>,
           <<"`text_grep`">>,
           <<"`text_head`">>]},
         {"docs/contracts/tool-catalog-test-contract.md",
          [<<"all seven built-ins">>,
           <<"`seeded_catalog_lists_all_seven_builtins_test_`">>]}],
    Missing =
        [{Path, Needle}
         || {Path, Needles} <- Expectations,
            {ok, Doc} <- [file:read_file(Path)],
            Needle <- Needles,
            binary:match(Doc, Needle) =:= nomatch],
    ?assertEqual([], Missing).
