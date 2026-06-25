-module(soma_v04_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/v0.4-test-contract.md").

%% Issue #73 criterion 10: `docs/contracts/v0.4-test-contract.md` lists the new
%% edge-case proofs added by this issue, each mapped to its suite and case. The
%% two new suites are `soma_actor_startup_SUITE` (the actor-only startup proof)
%% and `soma_actor_validation_SUITE` (malformed-steps and no-steps proofs). The
%% contract must name both suites together with the cases they contribute.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 10: the contract names the new startup suite and its only case.
test_doc_names_startup_suite_and_case() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_actor_startup_SUITE">>)),
    ?assert(contains(Doc, <<"actor_only_start_runs_steps_to_terminal">>)).

%% Criterion 10: the contract names the new validation suite and each of its
%% cases (malformed-steps and no-steps edge cases).
test_doc_names_validation_suite_and_cases() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"soma_actor_validation_SUITE">>)),
    ?assert(contains(Doc, <<"malformed_steps_rejected_or_failed_not_running">>)),
    ?assert(contains(Doc, <<"actor_alive_after_malformed_steps">>)),
    ?assert(contains(Doc, <<"valid_steps_complete_after_malformed">>)),
    ?assert(contains(Doc, <<"ask_no_steps_returns_ok_accepted">>)),
    ?assert(contains(Doc, <<"ask_no_steps_parks_no_waiter">>)),
    ?assert(contains(Doc, <<"send_no_steps_accepted_no_run">>)).

doc_names_startup_suite_and_case_test() ->
    test_doc_names_startup_suite_and_case().

doc_names_validation_suite_and_cases_test() ->
    test_doc_names_validation_suite_and_cases().
