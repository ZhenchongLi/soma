-module(soma_cli_3_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/cli-3-test-contract.md").

%% Issue #124 criterion 10: `docs/contracts/cli-3-test-contract.md' exists, is
%% non-empty, and names a proving suite or module and each of its case names for
%% every CLI.3 proof. The CLI.3 proofs live across the LFE read tests, the Lisp
%% renderer test, the server CT suite, the client CT suite, the two docs
%% deliverables, and the marker guard. The contract must name every suite/module
%% together with each of its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 10: the contract names every CLI.3 suite/module and each of its
%% cases.
test_doc_names_cli_3_suites_and_cases() ->
    Doc = read_doc(),
    ?assert(byte_size(Doc) > 0),
    %% LFE read tests (criteria 1, 2)
    ?assert(contains(Doc, <<"soma_lfe_read_tests">>)),
    ?assert(contains(Doc, <<"test_trace_compiles_to_trace_command">>)),
    ?assert(contains(Doc, <<"test_status_compiles_to_status_command">>)),
    %% Lisp renderer test (criterion 3)
    ?assert(contains(Doc, <<"soma_lisp_tests">>)),
    ?assert(contains(Doc, <<"test_render_result_map_with_task_id_emits_task_id_subform">>)),
    %% Server CT suite (criteria 4, 5, 6)
    ?assert(contains(Doc, <<"soma_cli_server_SUITE">>)),
    ?assert(contains(Doc, <<"test_trace_after_run_returns_ordered_chain_ending_completed">>)),
    ?assert(contains(Doc, <<"test_status_after_run_reports_state_completed">>)),
    ?assert(contains(Doc, <<"test_status_unknown_id_reports_unknown_and_server_survives">>)),
    %% Client CT suite (criteria 7, 8)
    ?assert(contains(Doc, <<"soma_cli_SUITE">>)),
    ?assert(contains(Doc, <<"test_trace_prints_reply_exit_zero">>)),
    ?assert(contains(Doc, <<"test_status_prints_reply_exit_zero">>)),
    %% Docs deliverables (criteria 9, 10)
    ?assert(contains(Doc, <<"cli.md">>)),
    ?assert(contains(Doc, <<"soma_cli_md_read_tests">>)),
    ?assert(contains(Doc, <<"test_cli_md_documents_status_trace_and_defers_cancel_detach">>)),
    ?assert(contains(Doc, <<"cli-3-test-contract.md">>)),
    ?assert(contains(Doc, <<"soma_cli_3_contract_tests">>)),
    ?assert(contains(Doc, <<"test_doc_names_cli_3_suites_and_cases">>)),
    %% Marker guard (criterion 11)
    ?assert(contains(Doc, <<"soma_cli_3_marker_tests">>)),
    ?assert(contains(Doc, <<"test_cli_3_sources_have_no_real_provider_or_socket_marker">>)).

doc_names_cli_3_suites_and_cases_test() ->
    test_doc_names_cli_3_suites_and_cases().
