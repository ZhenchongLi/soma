-module(soma_l4_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/L.4-test-contract.md").

%% Issue #112 criterion 6: `docs/contracts/` gains an L.4 entry that maps each
%% L.4 proof (the term->Lisp renderer slice) to its test suite/module and case
%% name. The L.4 proofs live across the pure renderer tests, the trace-render
%% suite, this doc-check, and the mock-only guard. The contract must name every
%% suite/module together with each of its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 6: the contract names every L.4 suite/module and each of its cases.
test_doc_names_l4_suites_and_cases() ->
    Doc = read_doc(),
    %% Pure renderer tests (criteria 1-3, 5)
    ?assert(contains(Doc, <<"soma_lisp_tests">>)),
    ?assert(contains(Doc, <<"test_render_result_map_produces_fixed_sexpr">>)),
    ?assert(contains(Doc, <<"test_render_event_map_carries_fields">>)),
    ?assert(contains(Doc, <<"test_render_pid_becomes_quoted_string">>)),
    ?assert(contains(Doc, <<"test_msg_envelope_round_trips_through_render">>)),
    %% Trace-render suite (criterion 4)
    ?assert(contains(Doc, <<"soma_trace_lisp_SUITE">>)),
    ?assert(contains(Doc, <<"test_render_lisp_orders_chain_by_timestamp">>)),
    %% Contract doc check (criterion 6)
    ?assert(contains(Doc, <<"soma_l4_contract_doc_tests">>)),
    ?assert(contains(Doc, <<"test_doc_names_l4_suites_and_cases">>)).

doc_names_l4_suites_and_cases_test() ->
    test_doc_names_l4_suites_and_cases().
