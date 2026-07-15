-module(soma_rs1b_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/RS.1b-test-contract.md").

%% Issue #244 criterion 19: the durable RS.1b contract must name the exact
%% proving module and case for every acceptance criterion.
test_rs1b_contract_maps_every_criterion_to_proving_case() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{<<"## Criterion 1 ">>,
          <<"soma_service_SUITE:test_supervised_service_restarts_and_serves_again">>},
         {<<"## Criterion 2 ">>,
          <<"soma_service_SUITE:test_single_tool_invocation_runs_without_llm_worker">>},
         {<<"## Criterion 3 ">>,
          <<"soma_service_SUITE:test_oversized_result_fails_with_max_output_reason">>},
         {<<"## Criterion 4 ">>,
          <<"soma_service_SUITE:test_flat_plan_preserves_order_and_from_step_output">>},
         {<<"## Criterion 5 ">>,
          <<"soma_service_SUITE:test_identical_duplicate_reuses_running_handle_and_terminal_result">>},
         {<<"## Criterion 6 ">>,
          <<"soma_service_SUITE:test_conflicting_request_id_rejected_before_new_run">>},
         {<<"## Criterion 7 ">>,
          <<"soma_service_SUITE:test_run_started_journals_request_id_and_envelope_hash">>},
         {<<"## Criterion 8 ">>,
          <<"soma_service_SUITE:test_durable_restart_rebuilds_dedupe_without_new_run_started">>},
         {<<"## Criterion 9 ">>,
          <<"soma_service_SUITE:test_out_of_scope_invocation_rejected_through_policy">>},
         {<<"## Criterion 10 ">>,
          <<"soma_service_SUITE:test_unscoped_invocation_uses_configured_or_empty_default_policy">>},
         {<<"## Criterion 11 ">>,
          <<"soma_service_SUITE:test_unknown_scope_entry_does_not_create_atom">>},
         {<<"## Criterion 12 ">>,
          <<"soma_service_SUITE:test_deadline_exceeded_cleans_run_worker_and_cli_process">>},
         {<<"## Criterion 13 ">>,
          <<"soma_service_SUITE:test_service_cancel_cleans_tool_worker_and_cli_process">>},
         {<<"## Criterion 14 ">>,
          <<"soma_service_SUITE:test_tool_crash_is_bounded_and_service_runs_again">>},
         {<<"## Criterion 15 ">>,
          <<"soma_service_SUITE:test_lifecycle_reads_are_monotonic">>},
         {<<"## Criterion 16 ">>,
          <<"soma_service_SUITE:test_unsafe_interrupted_state_invocation_recovers_in_doubt">>},
         {<<"## Criterion 17 ">>,
          <<"soma_service_SUITE:test_interrupted_reader_invocation_resumes_after_restart">>},
         {<<"## Criterion 18 ">>,
          <<"soma_service_boundary_tests:test_recovery_uses_shared_descriptor_safety_without_reverse_dependency">>},
         {<<"## Criterion 19 ">>,
          <<"soma_rs1b_contract_doc_tests:test_rs1b_contract_maps_every_criterion_to_proving_case">>}],
    lists:foreach(
        fun({Criterion, Proof}) ->
            ?assertEqual(1, length(binary:matches(Doc, Criterion))),
            ?assertEqual(1, length(binary:matches(Doc, Proof)))
        end,
        Mappings
    ).

rs1b_contract_maps_every_criterion_to_proving_case_test() ->
    test_rs1b_contract_maps_every_criterion_to_proving_case().
