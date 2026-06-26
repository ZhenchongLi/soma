-module(soma_l5_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/L.5-test-contract.md").

%% Issue #117 criterion 9: `docs/contracts/` gains an L.5 entry that maps each
%% L.5 proof to its test suite and case, matching the existing contract-doc
%% format. The L.5 proofs live across the bounded-repair actor suite, this
%% doc-check, and the mock-only guard. The contract must name every suite/module
%% together with each of its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 9: the contract names every L.5 suite/module and each of its cases.
test_doc_names_l5_suites_and_cases() ->
    Doc = read_doc(),
    %% Bounded-repair actor suite (criteria 1-8)
    ?assert(contains(Doc, <<"soma_actor_lisp_repair_SUITE">>)),
    ?assert(contains(Doc, <<"repaired_reply_reaches_same_terminal_result_as_valid_reply">>)),
    ?assert(contains(Doc, <<"successful_repair_emits_proposal_repaired_with_ids">>)),
    ?assert(contains(Doc, <<"repaired_run_steps_outside_allowlist_is_rejected">>)),
    ?assert(contains(Doc, <<"all_repairs_malformed_fails_after_max_attempts_with_diagnostics">>)),
    ?assert(contains(Doc, <<"actor_alive_after_repair_failure_runs_next_valid_message">>)),
    ?assert(contains(Doc, <<"repair_blocked_by_max_llm_calls_fails_budget_exceeded">>)),
    ?assert(contains(Doc, <<"strict_mode_fails_malformed_without_repair_call">>)),
    ?assert(contains(Doc, <<"valid_proposal_completes_with_one_llm_started_no_repair">>)),
    %% Contract doc check (criterion 9)
    ?assert(contains(Doc, <<"soma_l5_contract_doc_tests">>)),
    ?assert(contains(Doc, <<"test_doc_names_l5_suites_and_cases">>)),
    %% Mock-only guard (criterion 10)
    ?assert(contains(Doc, <<"soma_l5_mock_only_tests">>)),
    ?assert(contains(Doc, <<"test_every_llm_directive_is_the_proposal_mock">>)),
    ?assert(contains(Doc, <<"test_no_real_provider_config_in_suite">>)).

doc_names_l5_suites_and_cases_test() ->
    test_doc_names_l5_suites_and_cases().
