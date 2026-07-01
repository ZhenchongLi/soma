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

%% The contract also names the resume-executor suites (v0.7.2 seam, v0.7.3 plan,
%% v0.7.4 executor) and a representative case from each, so the executor layer is
%% documented alongside the journal/reconstruction layer.
test_doc_names_resume_executor_suites_and_cases() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_run_resume_seam_SUITE">>)),
    ?assert(contains(Doc, <<"test_resume_emits_run_resumed_with_first_pending_step">>)),
    ?assert(contains(Doc, <<"soma_run_resume_plan_SUITE">>)),
    ?assert(contains(Doc, <<"test_in_flight_unsafe_state_step_is_unsafe">>)),
    ?assert(contains(Doc, <<"soma_run_resume_executor_SUITE">>)),
    ?assert(contains(Doc, <<"test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason">>)).

doc_names_resume_executor_suites_and_cases_test() ->
    test_doc_names_resume_executor_suites_and_cases().

%% v0.7.5 criterion 6: the contract names the auto-resume discovery and boot
%% proof suites and each case that proves the auto-resume guarantees.
test_doc_names_auto_resume_suite_and_cases() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_event_store_persist_tests">>)),
    ?assert(contains(Doc, <<"test_restarted_disk_log_interrupted_runs_reports_started_without_terminal">>)),
    ?assert(contains(Doc, <<"test_restarted_disk_log_interrupted_runs_excludes_terminal_run">>)),
    ?assert(contains(Doc, <<"soma_run_auto_resume_SUITE">>)),
    ?assert(contains(Doc, <<"test_boot_with_event_store_log_resumes_between_steps_interrupted_run">>)),
    ?assert(contains(Doc, <<"test_boot_auto_resume_emits_run_resumed_for_first_pending_step">>)),
    ?assert(contains(Doc, <<"test_boot_auto_resume_fails_unsafe_in_flight_state_step">>)).

doc_names_auto_resume_suite_and_cases_test() ->
    test_doc_names_auto_resume_suite_and_cases().
