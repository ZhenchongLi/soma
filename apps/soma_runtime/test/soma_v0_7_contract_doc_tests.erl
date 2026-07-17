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
    ?assert(contains(Doc, <<"test_run_origin_is_fixed_allowlist">>)),
    ?assert(contains(
              Doc,
              <<"test_tool_invocation_waits_for_durable_tool_started_append">>)),
    ?assert(contains(
              Doc,
              <<"test_cancel_during_tool_started_append_prevents_effect">>)),
    ?assert(contains(Doc, <<"test_restarted_disk_log_by_run_exposes_run_started_journal">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_journaled_steps">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_journaled_durable_options">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_committed_outputs_by_step_id">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_first_uncommitted_step">>)),
    ?assert(contains(Doc, <<"test_reconstruct_returns_terminal_status">>)),
    ?assert(contains(Doc, <<"test_reconstruct_rejects_missing_run_started_journal">>)),
    ?assert(contains(Doc, <<"test_reconstruct_rejects_unknown_committed_step">>)),
    ?assert(contains(Doc, <<"test_reconstruct_rejects_non_prefix_commits">>)),
    ?assert(contains(Doc, <<"test_reconstruct_rejects_mismatched_run_id">>)),
    ?assert(contains(Doc, <<"test_reconstruct_rejects_malformed_step_shapes">>)),
    ?assert(contains(
              Doc,
              <<"test_reconstruct_rejects_malformed_tool_identity">>)),
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
    ?assert(contains(
              Doc,
              <<"test_recorded_unsafe_snapshot_cannot_be_softened">>)),
    ?assert(contains(
              Doc,
              <<"test_snapshotless_in_flight_fails_closed">>)),
    ?assert(contains(Doc, <<"soma_run_resume_executor_SUITE">>)),
    ?assert(contains(Doc, <<"test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason">>)),
    ?assert(contains(
              Doc,
              <<"test_descriptor_change_after_plan_fails_before_tool_invocation">>)).

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
    ?assert(contains(Doc, <<"test_boot_auto_resume_fails_unsafe_in_flight_state_step">>)),
    ?assert(contains(Doc, <<"test_boot_auto_resume_skips_legacy_unowned_journal">>)),
    ?assert(contains(Doc, <<"test_boot_auto_resume_skips_cli_detached_even_when_true">>)),
    ?assert(contains(Doc, <<"test_boot_auto_resume_skips_unknown_or_malformed_origin">>)),
    ?assert(contains(Doc, <<"test_boot_auto_resume_skips_missing_or_malformed_auto_resume">>)).

doc_names_auto_resume_suite_and_cases_test() ->
    test_doc_names_auto_resume_suite_and_cases().

%% Detached CLI recovery is edge-owned, but these races cross the v0.7 paused
%% resume and exact RunId-claim boundary. Keep the cross-layer proof table
%% mechanically pinned alongside the runtime resume contract.
test_doc_names_cli_owner_race_cases() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_cli_resume_SUITE">>)),
    ?assert(contains(
              Doc,
              <<"test_cancelled_start_in_doubt_survives_registry_replacement">>)),
    ?assert(contains(
              Doc,
              <<"test_uncommitted_fresh_admission_fails_closed_after_registry_restart">>)),
    ?assert(contains(
              Doc,
              <<"test_rejected_admission_outvotes_later_exact_acceptance">>)),
    ?assert(contains(
              Doc,
              <<"test_committed_before_accepted_is_rejected">>)),
    ?assert(contains(
              Doc,
              <<"test_timed_out_stop_cannot_close_admission_later">>)),
    ?assert(contains(
              Doc,
              <<"test_timed_out_open_admission_cannot_rebind_dead_owner">>)),
    ?assert(contains(
              Doc,
              <<"test_live_rebind_ignores_old_owner_down">>)),
    ?assert(contains(
              Doc,
              <<"test_controlled_stop_retires_blocked_registry_workers">>)),
    ?assert(contains(
              Doc,
              <<"test_timed_out_detached_start_has_no_late_effect">>)),
    ?assert(contains(
              Doc,
              <<"test_timed_out_prepare_retires_claim_and_rejects_late_journal">>)),
    ?assert(contains(
              Doc,
              <<"test_timed_out_supervisor_start_leaves_no_claim_or_effect">>)),
    ?assert(contains(
              Doc,
              <<"test_rebound_tools_dir_is_used_after_tool_registry_restart">>)).

doc_names_cli_owner_race_cases_test() ->
    test_doc_names_cli_owner_race_cases().
