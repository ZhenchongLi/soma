-module(soma_as3_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/AS.3-test-contract.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

test_as3_contract_names_every_acceptance_proof() ->
    Doc = read_doc(),
    Proofs =
        [<<"soma_actor_explore_SUITE:explore_mode_provider_text_is_parsed_as_round_reply">>,
         <<"soma_actor_call_opts_tests:test_explore_prompt_reuses_policy_filtered_catalog_blocks">>,
         <<"soma_actor_call_opts_tests:test_explore_prompt_states_protocol_round_and_remaining_allowance">>,
         <<"soma_actor_explore_SUITE:reader_explore_run_and_tool_worker_are_distinct_children">>,
         <<"soma_actor_explore_SUITE:reader_then_terminal_run_steps_carries_observation_and_outputs">>,
         <<"soma_actor_explore_SUITE:non_reader_explore_rejected_with_effect_and_no_run">>,
         <<"soma_actor_explore_SUITE:configured_observation_cap_counts_only_retained_output_bytes">>,
         <<"soma_actor_explore_SUITE:default_observation_cap_is_16384_bytes">>,
         <<"soma_actor_explore_SUITE:failed_explore_run_becomes_next_round_observation">>,
         <<"soma_actor_explore_SUITE:timed_out_explore_run_becomes_next_round_observation">>,
         <<"soma_actor_explore_SUITE:invalid_round_reply_becomes_bounded_next_observation">>,
         <<"soma_actor_explore_SUITE:configured_round_limit_stops_before_next_llm_start">>,
         <<"soma_actor_explore_SUITE:default_round_limit_is_five">>,
         <<"soma_actor_explore_SUITE:explore_rounds_consume_existing_llm_call_budget">>,
         <<"soma_actor_explore_SUITE:in_loop_llm_crash_is_terminal_failed">>,
         <<"soma_actor_explore_SUITE:in_loop_llm_timeout_is_terminal_timeout">>,
         <<"soma_actor_explore_SUITE:cancel_during_llm_round_kills_worker_and_cancels_task">>,
         <<"soma_actor_explore_SUITE:cancel_during_explore_run_kills_tool_worker_and_cancels_task">>,
         <<"soma_actor_explore_SUITE:actor_reusable_after_round_exhaustion">>,
         <<"soma_actor_explore_SUITE:actor_reusable_after_in_loop_llm_failure">>,
         <<"soma_actor_explore_SUITE:actor_reusable_after_exploration_cancel">>,
         <<"soma_actor_explore_SUITE:terminal_run_steps_reuses_proposal_execution_suffix">>,
         <<"soma_actor_explore_SUITE:terminal_reply_completes_without_run">>,
         <<"soma_actor_explore_SUITE:terminal_policy_rejection_starts_no_run">>,
         <<"soma_actor_explore_SUITE:terminal_max_steps_failure_starts_no_run">>,
         <<"soma_actor_explore_SUITE:round_events_use_bounded_schema_and_order">>,
         <<"soma_trace_tests:test_timeline_renders_explore_round_number">>,
         <<"soma_trace_tests:test_render_prints_explore_rounds_in_order_before_terminal_suffix">>,
         <<"soma_as3_contract_doc_tests:test_as3_contract_names_every_acceptance_proof">>],
    lists:foreach(
        fun(Proof) ->
            ?assert(contains(Doc, Proof))
        end,
        Proofs
    ).

as3_contract_names_every_acceptance_proof_test() ->
    test_as3_contract_names_every_acceptance_proof().
