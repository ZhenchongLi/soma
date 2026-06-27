-module(soma_v0_7_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/v0.7-test-contract.md").

%% Issue #129 criterion 13: `docs/contracts/v0.7-test-contract.md` maps each
%% resume journal guarantee to a test case. The guarantees all live in
%% `soma_run_resume_journal_SUITE'; the contract must name that suite and each
%% of its case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 13: the contract names the resume journal suite and each case.
test_doc_names_resume_journal_suite_and_cases() ->
    Doc = read_doc(),
    %% Staged red: assert the doc names a suite it must NOT name, so the
    %% assertion genuinely fires before the doc exists / is corrected.
    ?assert(contains(Doc, <<"soma_run_resume_journal_SUITE_WRONG_NAME">>)),
    ?assert(contains(Doc, <<"soma_run_resume_journal_SUITE">>)),
    ?assert(contains(Doc, <<"test_session_start_journals_steps_in_run_started">>)),
    ?assert(contains(Doc, <<"test_direct_run_journals_durable_options_with_correlation_id">>)),
    ?assert(contains(Doc, <<"test_restarted_disk_log_by_run_exposes_run_started_journal">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_journaled_steps">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_journaled_durable_options">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_committed_outputs_by_step_id">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_first_uncommitted_step">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_terminal_status">>)),
    ?assert(contains(Doc, <<"test_reconstruct_rejects_missing_run_started_journal">>)),
    ?assert(contains(Doc, <<"test_reconstruct_rejects_unknown_committed_step">>)),
    ?assert(contains(Doc, <<"test_reconstruct_does_not_append_events">>)),
    ?assert(contains(Doc, <<"test_reconstruct_does_not_start_run_children">>)).

doc_names_resume_journal_suite_and_cases_test() ->
    test_doc_names_resume_journal_suite_and_cases().
