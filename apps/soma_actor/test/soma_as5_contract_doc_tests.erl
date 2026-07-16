-module(soma_as5_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/AS.5-test-contract.md").

%% Issue #233 criterion 17: the durable AS.5 contract must map every
%% acceptance criterion to exactly one hermetic, provider-network-free proof.
test_as5_contract_maps_every_criterion_to_one_hermetic_test() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{1,
          <<"soma_delegate_adaptive_SUITE:test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs">>},
         {2,
          <<"soma_delegate_adaptive_SUITE:test_prompt_projection_uses_exact_task_local_fields">>},
         {3,
          <<"soma_delegate_adaptive_SUITE:test_model_action_admission_order_and_state_spine">>},
         {4,
          <<"soma_delegate_adaptive_SUITE:test_denied_and_malformed_actions_stop_before_run">>},
         {5,
          <<"soma_delegate_adaptive_SUITE:test_reader_state_terminal_sequence_threads_observations">>},
         {6,
          <<"soma_delegate_adaptive_SUITE:test_failed_and_timed_out_actions_feed_observations_with_fresh_invocations">>},
         {7,
          <<"soma_delegate_adaptive_SUITE:test_prompt_schemas_equal_policy_capability_intersection">>},
         {8,
          <<"soma_delegate_adaptive_SUITE:test_round_llm_and_tool_budgets_stop_before_child_start_and_reset">>},
         {9,
          <<"soma_delegate_adaptive_SUITE:test_task_deadline_tears_down_all_owned_execution_children">>},
         {10,
          <<"soma_delegate_adaptive_SUITE:test_context_preflight_and_provider_usage_accounting">>},
         {11,
          <<"soma_delegate_adaptive_SUITE:test_oversized_observation_uses_stable_task_artifact_and_bounded_slice">>},
         {12,
          <<"soma_delegate_adaptive_SUITE:test_recent_round_window_replaces_old_observations_with_one_summary">>},
         {13,
          <<"soma_delegate_adaptive_SUITE:test_pinned_safety_state_is_exact_and_never_truncated">>},
         {14,
          <<"soma_delegate_adaptive_SUITE:test_maximum_round_prompts_obey_cumulative_input_bound">>},
         {15,
          <<"soma_delegate_adaptive_SUITE:test_adaptive_events_are_documented_scrubbed_and_4096_byte_bounded">>},
         {16,
          <<"soma_delegate_adaptive_SUITE:test_terminal_projection_has_exact_public_contract">>},
         {17,
          <<"soma_as5_contract_doc_tests:test_as5_contract_maps_every_criterion_to_one_hermetic_test">>}],
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
                                               hermetic_proof_line(Proof)))),
            ?assertEqual(1,
                         length(binary:matches(Section,
                                               <<"- Hermetic boundary:">>))),
            ?assertEqual(1,
                         length(binary:matches(Section,
                                               <<"zero provider network connections">>)))
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
