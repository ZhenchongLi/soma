-module(soma_l3_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/L.3-test-contract.md").

%% Issue #109 criterion 8: `docs/contracts/` gains an L.3 entry that maps each
%% L.3 proof (criteria 1-9) to its test suite/module and case name. The L.3
%% proofs live across the Lisp-proposal parser tests, the end-to-end actor
%% suite, this doc-check, and the mock-only guard. The contract must name every
%% suite/module together with each of its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 8: the contract names every L.3 suite/module and each of its cases.
test_doc_names_l3_suites_and_cases() ->
    Doc = read_doc(),
    %% Parser-level proposal tests (criteria 1-3)
    ?assert(contains(Doc, <<"soma_lfe_proposal_tests">>)),
    ?assert(contains(Doc, <<"test_reply_form_normalizes_to_reply_kind">>)),
    ?assert(contains(Doc, <<"test_run_steps_form_normalizes_with_equivalent_steps">>)),
    ?assert(contains(Doc, <<"test_malformed_proposal_form_returns_diagnostic">>)),
    %% End-to-end actor suite (criteria 4-7)
    ?assert(contains(Doc, <<"soma_actor_lisp_proposal_SUITE">>)),
    ?assert(contains(Doc, <<"lisp_reply_reaches_same_terminal_result_as_map_reply">>)),
    ?assert(contains(Doc, <<"lisp_run_steps_emits_proposal_executed_and_runs">>)),
    ?assert(contains(Doc, <<"malformed_lisp_proposal_fails_task_actor_alive">>)),
    ?assert(contains(Doc, <<"map_proposal_path_unchanged">>)),
    %% Contract doc check (criterion 8)
    ?assert(contains(Doc, <<"soma_l3_contract_doc_tests">>)),
    ?assert(contains(Doc, <<"test_doc_names_l3_suites_and_cases">>)),
    %% Mock-only guard (criterion 9)
    ?assert(contains(Doc, <<"soma_l3_mock_only_tests">>)),
    ?assert(contains(Doc, <<"test_every_llm_directive_is_the_proposal_mock">>)),
    ?assert(contains(Doc, <<"test_no_real_provider_config_in_suite">>)).

doc_names_l3_suites_and_cases_test() ->
    test_doc_names_l3_suites_and_cases().
