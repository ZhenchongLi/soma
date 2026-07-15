-module(soma_rs1c_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/RS.1c-test-contract.md").

%% Issue #245 criterion 10: the durable RS.1c contract must name the exact
%% proving module and case for every acceptance criterion.
test_rs1c_contract_maps_every_criterion_to_proving_case() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{<<"## Criterion 1 ">>,
          <<"soma_service_SUITE:test_terminal_status_has_bounded_summary_only">>},
         {<<"## Criterion 2 ">>,
          <<"soma_service_SUITE:test_result_inline_uses_default_and_configured_cap">>},
         {<<"## Criterion 3 ">>,
          <<"soma_service_SUITE:test_oversized_result_publishes_stable_artifact">>},
         {<<"## Criterion 4 ">>,
          <<"soma_service_artifact_tests:test_failed_publication_cleans_only_owned_temp">>},
         {<<"## Criterion 5 ">>,
          <<"soma_service_SUITE:test_missing_correlation_defaults_to_task_watch_order">>},
         {<<"## Criterion 6 ">>,
          <<"soma_service_SUITE:test_watch_cursor_resumes_and_page_limit_is_clamped">>},
         {<<"## Criterion 7 ">>,
          <<"soma_service_SUITE:test_watch_recursively_scrubs_secrets_runtime_terms_and_large_payloads">>},
         {<<"## Criterion 8 ">>,
          <<"soma_service_SUITE:test_cancel_is_terminal_and_idempotent_after_teardown">>},
         {<<"## Criterion 9 ">>,
          <<"soma_service_SUITE:test_result_and_watch_unknown_task_are_not_found">>},
         {<<"## Criterion 10 ">>,
          <<"soma_rs1c_contract_doc_tests:test_rs1c_contract_maps_every_criterion_to_proving_case">>}],
    lists:foreach(
        fun({Criterion, Proof}) ->
            ?assertEqual(1, length(binary:matches(Doc, Criterion))),
            ?assertEqual(1, length(binary:matches(Doc, Proof)))
        end,
        Mappings
    ).

rs1c_contract_maps_every_criterion_to_proving_case_test() ->
    test_rs1c_contract_maps_every_criterion_to_proving_case().
