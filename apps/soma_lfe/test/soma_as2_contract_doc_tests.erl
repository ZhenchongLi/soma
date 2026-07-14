-module(soma_as2_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/AS.2-test-contract.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

test_as2_contract_names_every_acceptance_proof() ->
    Doc = read_doc(),
    Proofs =
        [<<"soma_lfe_explore_tests:test_explore_compiles_canonical_steps_and_matches_run_steps">>,
         <<"soma_lfe_explore_tests:test_explore_compile_starts_no_processes_or_events">>,
         <<"soma_lfe_explore_tests:test_explore_and_run_steps_share_proposal_step_production">>,
         <<"soma_lfe_explore_tests:test_explore_source_keeps_dependency_and_atom_creation_boundaries">>,
         <<"soma_lfe_explore_tests:test_empty_explore_returns_fixed_diagnostic">>,
         <<"soma_lfe_explore_tests:test_malformed_explore_step_returns_fixed_diagnostic">>,
         <<"soma_lfe_explore_tests:test_unknown_explore_level_form_returns_fixed_diagnostic">>,
         <<"soma_lisp_explore_tests:test_canonical_explore_maps_round_trip_through_render_and_compile">>,
         <<"soma_as2_contract_doc_tests:test_as2_contract_names_every_acceptance_proof">>],
    lists:foreach(
        fun(Proof) ->
            ?assert(contains(Doc, Proof))
        end,
        Proofs
    ).

as2_contract_names_every_acceptance_proof_test() ->
    test_as2_contract_names_every_acceptance_proof().
