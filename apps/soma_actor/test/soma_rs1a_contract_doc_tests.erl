-module(soma_rs1a_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/RS.1a-test-contract.md").

%% Issue #243 criterion 6: the durable RS.1a contract must name the exact
%% proving module and case for every acceptance criterion.
test_rs1a_contract_maps_every_criterion_to_proving_case() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{<<"## Criterion 1 ">>,
          <<"soma_service_envelope_tests:test_valid_tool_invoke_compiles_and_normalizes">>},
         {<<"## Criterion 2 ">>,
          <<"soma_service_envelope_tests:test_valid_steps_invoke_matches_run_steps_production">>},
         {<<"## Criterion 3 ">>,
          <<"soma_service_envelope_tests:test_invalid_invoke_classes_return_fixed_typed_errors">>},
         {<<"## Criterion 4 ">>,
          <<"soma_lisp_invoke_tests:test_canonical_invoke_maps_round_trip_through_render_and_compile">>},
         {<<"## Criterion 5 ">>,
          <<"soma_service_envelope_tests:test_invoke_compile_normalize_boundary_is_pure">>},
         {<<"## Criterion 6 ">>,
          <<"soma_rs1a_contract_doc_tests:test_rs1a_contract_maps_every_criterion_to_proving_case">>}],
    lists:foreach(
        fun({Criterion, Proof}) ->
            ?assertEqual(1, length(binary:matches(Doc, Criterion))),
            ?assertEqual(1, length(binary:matches(Doc, Proof)))
        end,
        Mappings
    ).

rs1a_contract_maps_every_criterion_to_proving_case_test() ->
    test_rs1a_contract_maps_every_criterion_to_proving_case().
