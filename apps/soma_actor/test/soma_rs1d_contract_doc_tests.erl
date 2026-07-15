-module(soma_rs1d_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/RS.1d-test-contract.md").

%% Issue #246 criterion 12: the durable RS.1d contract must name the exact
%% proving module and case for every acceptance criterion.
test_rs1d_contract_maps_every_criterion_to_proving_case() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{<<"## Criterion 1 ">>,
          <<"soma_service_socket_SUITE:test_socket_invoke_status_and_result_end_to_end">>},
         {<<"## Criterion 2 ">>,
          <<"soma_service_socket_SUITE:test_socket_disconnect_does_not_cancel_accepted_invocation">>},
         {<<"## Criterion 3 ">>,
          <<"soma_service_socket_SUITE:test_socket_duplicate_invoke_reuses_task_once">>},
         {<<"## Criterion 4 ">>,
          <<"soma_service_socket_SUITE:test_socket_watch_reconnect_resumes_after_cursor">>},
         {<<"## Criterion 5 ">>,
          <<"soma_service_socket_SUITE:test_socket_cancel_is_repeatable_after_cli_process_exit">>},
         {<<"## Criterion 6 ">>,
          <<"soma_service_socket_SUITE:test_socket_version_and_operation_errors_are_typed">>},
         {<<"## Criterion 7 ">>,
          <<"soma_service_socket_SUITE:test_socket_rejects_bad_and_oversized_frames_then_serves">>},
         {<<"## Criterion 8 ">>,
          <<"soma_service_socket_SUITE:test_daemon_service_listener_is_config_opt_in_with_sibling_default">>},
         {<<"## Criterion 9 ">>,
          <<"soma_service_socket_SUITE:test_service_socket_stale_takeover_and_lost_bind_preserve_winner">>},
         {<<"## Criterion 10 ">>,
          <<"soma_service_socket_boundary_tests:test_socket_adapters_share_transport_and_service_keeps_runtime_boundary">>},
         {<<"## Criterion 11 ">>,
          <<"soma_service_contract_doc_tests:test_service_contract_defines_compatibility_matrix">>},
         {<<"## Criterion 12 ">>,
          <<"soma_rs1d_contract_doc_tests:test_rs1d_contract_maps_every_criterion_to_proving_case">>}],
    lists:foreach(
        fun({Criterion, Proof}) ->
            ?assertEqual(1, length(binary:matches(Doc, Criterion))),
            ?assertEqual(1, length(binary:matches(Doc, Proof)))
        end,
        Mappings
    ).

rs1d_contract_maps_every_criterion_to_proving_case_test() ->
    test_rs1d_contract_maps_every_criterion_to_proving_case().
