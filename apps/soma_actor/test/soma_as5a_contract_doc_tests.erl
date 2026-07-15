-module(soma_as5a_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/AS.5a-test-contract.md").

%% Issue #234 criterion 18: the durable AS.5a contract must map every
%% acceptance criterion to exactly one explicitly hermetic proving case.
test_as5a_contract_maps_every_criterion_to_one_hermetic_test() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{1,
          <<"soma_delegate_SUITE:test_request_identity_reuses_one_live_coordinator">>},
         {2,
          <<"soma_delegate_SUITE:test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections">>},
         {3,
          <<"soma_delegate_SUITE:test_status_and_cancel_route_by_task_id">>},
         {4,
          <<"soma_delegate_SUITE:test_coordinator_and_round_worker_crashes_leave_ingress_responsive">>},
         {5,
          <<"soma_delegate_SUITE:test_delegate_action_crosses_full_worker_run_tool_spine">>},
         {6,
          <<"soma_delegate_SUITE:test_coordinator_and_round_worker_split_child_ownership">>},
         {7,
          <<"soma_delegate_SUITE:test_sequential_rounds_commit_before_distinct_next_worker">>},
         {8,
          <<"soma_delegate_SUITE:test_round_snapshot_is_bounded_task_only_and_handle_scoped">>},
         {9,
          <<"soma_delegate_SUITE:test_round_result_identity_rejects_stale_duplicate_and_mismatched_messages">>},
         {10,
          <<"soma_delegate_SUITE:test_pre_stateful_worker_crash_and_timeout_are_bounded">>},
         {11,
          <<"soma_delegate_SUITE:test_lost_state_result_is_in_doubt_without_replacement">>},
         {12,
          <<"soma_delegate_SUITE:test_task_leases_are_stable_and_released_once_for_all_outcomes">>},
         {13,
          <<"soma_delegate_SUITE:test_cancel_tears_down_llm_run_tool_and_os_children_once">>},
         {14,
          <<"soma_delegate_SUITE:test_concurrent_tasks_isolate_state_workers_and_leases">>},
         {15,
          <<"soma_delegate_SUITE:test_terminal_cleanup_scrubs_task_state_before_fresh_request">>},
         {16,
          <<"soma_delegate_SUITE:test_delegate_events_are_bounded_stable_and_scrubbed">>},
         {17,
          <<"soma_delegate_SUITE:test_completed_delegate_preserves_existing_result_contracts">>},
         {18,
          <<"soma_as5a_contract_doc_tests:test_as5a_contract_maps_every_criterion_to_one_hermetic_test">>}],
    ?assertEqual(length(Mappings),
                 length(binary:matches(Doc, <<"## Criterion ">>))),
    lists:foreach(
        fun({Number, Proof}) ->
            Heading = criterion_heading(Number),
            ?assertEqual(1, length(binary:matches(Doc, Heading))),
            ?assertEqual(1, length(binary:matches(Doc, Proof))),
            Section = criterion_section(Doc, Heading),
            ?assertEqual(1,
                         length(binary:matches(Section,
                                               <<"- Hermetic proof:">>))),
            ?assertEqual(1,
                         length(binary:matches(Section,
                                               hermetic_proof_line(Proof)))),
            ?assertEqual(1,
                         length(binary:matches(Section,
                                               <<"- Hermetic boundary:">>)))
        end,
        Mappings
    ).

criterion_heading(Number) ->
    <<"## Criterion ", (integer_to_binary(Number))/binary, " ">>.

criterion_section(Doc, Heading) ->
    [_, AfterHeading] = binary:split(Doc, Heading),
    [Section | _] = binary:split(AfterHeading, <<"\n## Criterion ">>),
    Section.

hermetic_proof_line(Proof) ->
    <<"- Hermetic proof: `", Proof/binary, "`">>.
