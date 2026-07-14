-module(soma_as4_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(USAGE_DOC, "docs/usage.md").
-define(CONTRACT_DOC, "docs/contracts/AS.4-test-contract.md").

test_usage_documents_explore_settings_and_docmod_registration() ->
    Doc = read_file(?USAGE_DOC),
    ?assert(contains(Doc, <<"explore = true">>)),
    ?assert(contains(Doc, <<"max_explore_rounds =">>)),
    ?assert(contains(Doc, <<"max_observation_bytes =">>)),
    ?assert(contains(Doc, <<"positive integers">>)),
    ?assert(contains(Doc, <<"all three explore settings">>)),
    ?assert(contains(Doc, <<"examples/docmod-tools/docmod_help.lisp">>)),
    ?assert(contains(Doc, <<"examples/docmod-tools/docmod_read.lisp">>)),
    ?assert(contains(Doc, <<"examples/docmod-tools/docmod_edit.lisp">>)),
    ?assert(contains(Doc, <<"/REPLACE/WITH/PATH/TO/docmod">>)),
    ?assert(contains(Doc,
                     <<"cp docmod_help.lisp ~/.soma/tools/docmod_help.lisp">>)),
    ?assert(contains(Doc,
                     <<"cp docmod_read.lisp ~/.soma/tools/docmod_read.lisp">>)),
    ?assert(contains(Doc,
                     <<"cp docmod_edit.lisp ~/.soma/tools/docmod_edit.lisp">>)).

usage_documents_explore_settings_and_docmod_registration_test() ->
    test_usage_documents_explore_settings_and_docmod_registration().

test_as4_contract_maps_every_criterion_to_proving_case() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{<<"## Criterion 1 ">>,
          <<"soma_config_tests:test_load_carries_explore_true">>},
         {<<"## Criterion 2 ">>,
          <<"soma_cli_server_SUITE:test_explore_ask_uses_configured_round_and_observation_budgets">>},
         {<<"## Criterion 3 ">>,
          <<"soma_config_tests:test_invalid_explore_settings_emit_keyed_diagnostics">>},
         {<<"## Criterion 4 ">>,
          <<"soma_cli_server_SUITE:test_unparseable_explore_setting_keeps_daemon_reachable_and_off">>},
         {<<"## Criterion 5 ">>,
          <<"soma_cli_server_SUITE:test_config_loaded_explore_ask_returns_terminal_result_with_bounded_observation">>},
         {<<"## Criterion 6 ">>,
          <<"soma_cli_server_SUITE:test_trace_after_explore_ask_returns_rounds_in_event_order">>},
         {<<"## Criterion 7 ">>,
          <<"soma_cli_server_SUITE:test_explore_ask_client_disconnect_cancels_actor_task">>},
         {<<"## Criterion 8 ">>,
          <<"soma_tool_config_SUITE:test_docmod_example_manifests_normalize_with_expected_metadata">>},
         {<<"## Criterion 9 ">>,
          <<"soma_tool_config_SUITE:test_docmod_help_stub_receives_help_then_substituted_topic">>},
         {<<"## Criterion 10 ">>,
          <<"soma_as4_contract_doc_tests:test_usage_documents_explore_settings_and_docmod_registration">>},
         {<<"## Criterion 11 ">>,
          <<"soma_as4_contract_doc_tests:test_as4_contract_maps_every_criterion_to_proving_case">>}],
    lists:foreach(
        fun({Criterion, Proof}) ->
            ?assertEqual(1, length(binary:matches(Doc, Criterion))),
            ?assertEqual(1, length(binary:matches(Doc, Proof)))
        end,
        Mappings
    ).

as4_contract_maps_every_criterion_to_proving_case_test() ->
    test_as4_contract_maps_every_criterion_to_proving_case().

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).
