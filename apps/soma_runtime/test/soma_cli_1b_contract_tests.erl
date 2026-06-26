-module(soma_cli_1b_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/cli-1b-test-contract.md").

%% Issue #110 criterion 12: `docs/contracts/cli-1b-test-contract.md` names, for
%% each CLI.1b proof, the suite and case that proves it. The CLI.1b proofs live
%% across the server CT suite, the server source-text tests, the client CT
%% suite, the marker guard, and the two docs deliverables. The contract must
%% name every suite/module together with each of its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 12: the contract names every CLI.1b suite/module and each of its
%% cases.
test_doc_names_cli_1b_suites_and_cases() ->
    Doc = read_doc(),
    ?assert(byte_size(Doc) > 0),
    %% Server CT suite (criteria 1, 2, 4, 5, 6, 7)
    ?assert(contains(Doc, <<"soma_cli_server_SUITE">>)),
    ?assert(contains(Doc, <<"test_run_lisp_echo_returns_completed_result">>)),
    ?assert(contains(Doc, <<"test_run_lisp_result_carries_correlation_id">>)),
    ?assert(contains(Doc, <<"test_run_lisp_failed_returns_error_result">>)),
    ?assert(contains(Doc, <<"test_server_serves_after_failed_lisp_run">>)),
    ?assert(contains(Doc, <<"test_malformed_request_returns_error_sexpr">>)),
    ?assert(contains(Doc, <<"test_server_serves_after_malformed_request">>)),
    %% Server source-text tests (criterion 3)
    ?assert(contains(Doc, <<"soma_cli_server_tests">>)),
    ?assert(contains(Doc, <<"test_run_path_uses_lisp_not_json">>)),
    %% Client CT suite (criteria 8, 9, 10, 11)
    ?assert(contains(Doc, <<"soma_cli_SUITE">>)),
    ?assert(contains(Doc, <<"test_run_echo_file_prints_result_exit_zero">>)),
    ?assert(contains(Doc, <<"test_run_failed_workflow_exit_nonzero">>)),
    ?assert(contains(Doc, <<"test_run_reads_workflow_from_stdin_dash">>)),
    ?assert(contains(Doc, <<"test_daemon_boots_listener_client_connects">>)),
    %% Docs deliverables (criteria 12, 13)
    ?assert(contains(Doc, <<"cli-1b-test-contract.md">>)),
    ?assert(contains(Doc, <<"cli-test-contract.md">>)),
    %% Marker guard (criterion 14)
    ?assert(contains(Doc, <<"soma_cli_1b_marker_tests">>)),
    ?assert(contains(Doc, <<"test_cli_1b_sources_have_no_real_provider_or_socket_marker">>)).

doc_names_cli_1b_suites_and_cases_test() ->
    test_doc_names_cli_1b_suites_and_cases().
