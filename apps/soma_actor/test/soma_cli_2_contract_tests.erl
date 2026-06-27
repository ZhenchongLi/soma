-module(soma_cli_2_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/cli-2-test-contract.md").

%% Issue #122 criterion 9: `docs/contracts/cli-2-test-contract.md` exists and
%% names a proving suite or module and a case name for each acceptance criterion
%% above (criteria 1-10). The CLI.2 proofs live across the LFE ask tests, the
%% server CT suite, the client CT suite, the two docs deliverables, and the
%% marker guard. The contract must name every suite/module together with each of
%% its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 9: the contract names every CLI.2 suite/module and each of its
%% cases.
test_doc_names_cli_2_suites_and_cases() ->
    Doc = read_doc(),
    ?assert(byte_size(Doc) > 0),
    %% LFE ask tests (criteria 1, 2, 3)
    ?assert(contains(Doc, <<"soma_lfe_ask_tests">>)),
    ?assert(contains(Doc, <<"test_ask_intent_parses_to_ask_map">>)),
    ?assert(contains(Doc, <<"test_ask_without_intent_returns_error">>)),
    ?assert(contains(Doc, <<"test_ask_allow_and_budget_parse">>)),
    %% Server CT suite (criteria 4, 5, 6)
    ?assert(contains(Doc, <<"soma_cli_server_SUITE">>)),
    ?assert(contains(Doc, <<"test_ask_reply_returns_completed_result_with_text">>)),
    ?assert(contains(Doc, <<"test_ask_reject_returns_rejected_result_with_reason">>)),
    ?assert(contains(Doc, <<"test_ask_budget_llm_zero_returns_budget_exceeded">>)),
    %% Client CT suite (criterion 7)
    ?assert(contains(Doc, <<"soma_cli_SUITE">>)),
    ?assert(contains(Doc, <<"test_ask_prints_reply_result_exit_zero">>)),
    %% Docs deliverables (criteria 8, 9)
    ?assert(contains(Doc, <<"cli.md">>)),
    ?assert(contains(Doc, <<"cli-2-test-contract.md">>)),
    %% Marker guard (criterion 10)
    ?assert(contains(Doc, <<"soma_cli_2_marker_tests">>)),
    ?assert(contains(Doc, <<"test_cli_2_sources_have_no_real_provider_or_socket_marker">>)).

doc_names_cli_2_suites_and_cases_test() ->
    test_doc_names_cli_2_suites_and_cases().
