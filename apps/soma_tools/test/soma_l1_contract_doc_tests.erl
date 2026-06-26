-module(soma_l1_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/L.1-test-contract.md").

%% Issue #103 criterion 10: `docs/contracts/` gains an L.1 entry that maps each
%% L.1 proof to the suite and case that proves it. The two suites added by this
%% slice are `soma_lfe_message_tests` (the parser-level proofs, criteria 1-4)
%% and `soma_actor_lisp_message_SUITE` (the end-to-end actor proofs, criteria
%% 5-9). The contract must name both suites together with each case they
%% contribute.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 10: the contract names the parser suite and each of its cases.
test_doc_names_parser_suite_and_cases() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_lfe_message_tests">>)),
    ?assert(contains(Doc, <<"test_msg_form_produces_envelope_map">>)),
    ?assert(contains(Doc, <<"test_msg_form_carries_correlation_id_and_llm">>)),
    ?assert(contains(Doc, <<"test_malformed_msg_returns_diagnostics">>)),
    ?assert(contains(Doc, <<"test_run_form_unchanged_after_msg_added">>)).

%% Criterion 10: the contract names the actor suite and each of its cases.
test_doc_names_actor_suite_and_cases() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_actor_lisp_message_SUITE">>)),
    ?assert(contains(Doc, <<"test_lisp_send_matches_map_send_outputs">>)),
    ?assert(contains(Doc, <<"test_lisp_send_correlation_chain_matches_map">>)),
    ?assert(contains(Doc, <<"test_malformed_lisp_send_actor_survives">>)),
    ?assert(contains(Doc, <<"test_lisp_ask_matches_map_ask_result">>)),
    ?assert(contains(Doc, <<"test_map_send_path_untouched">>)).

doc_names_parser_suite_and_cases_test() ->
    test_doc_names_parser_suite_and_cases().

doc_names_actor_suite_and_cases_test() ->
    test_doc_names_actor_suite_and_cases().
