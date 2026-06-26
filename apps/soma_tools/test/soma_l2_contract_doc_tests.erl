-module(soma_l2_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/L.2-test-contract.md").

%% Issue #107 criterion 7: `docs/contracts/` gains an L.2 entry that maps each
%% L.2 proof to its test suite and case name. The L.2 proofs all live in the
%% single suite `soma_actor_lisp_to_lisp_SUITE` (actor-to-actor Lisp delivery).
%% The contract must name that suite together with each of its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 7: the contract names the L.2 suite and each of its cases.
test_doc_names_lisp_to_lisp_suite_and_cases() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_actor_lisp_to_lisp_SUITE">>)),
    ?assert(contains(Doc, <<"lisp_body_reaches_same_terminal_status_as_map">>)),
    ?assert(contains(Doc, <<"lisp_body_produces_same_step_outputs_as_map">>)),
    ?assert(contains(Doc, <<"by_correlation_spans_both_actors_for_lisp_body">>)),
    ?assert(contains(Doc, <<"malformed_lisp_body_marks_task_failed">>)),
    ?assert(contains(Doc, <<"actor_alive_and_accepts_after_malformed_body">>)),
    ?assert(contains(Doc, <<"map_body_path_unchanged">>)).

doc_names_lisp_to_lisp_suite_and_cases_test() ->
    test_doc_names_lisp_to_lisp_suite_and_cases().
