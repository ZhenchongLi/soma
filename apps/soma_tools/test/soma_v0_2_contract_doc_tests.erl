-module(soma_v0_2_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/v0.2-test-contract.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 1: the contract doc exists and a top-level heading names it as the
%% v0.2 process-behaviour test contract.
test_contract_doc_has_heading() ->
    Doc = read_doc(),
    Lines = binary:split(Doc, <<"\n">>, [global]),
    Headings = [L || L <- Lines, is_top_level_heading(L)],
    ?assert(lists:any(fun names_contract/1, Headings)).

is_top_level_heading(<<"# ", _/binary>>) -> true;
is_top_level_heading(_) -> false.

names_contract(Line) ->
    Lower = string:lowercase(Line),
    contains(Lower, <<"v0.2">>)
        andalso contains(Lower, <<"process-behaviour">>)
        andalso contains(Lower, <<"contract">>).

contract_doc_has_heading_test() ->
    test_contract_doc_has_heading().

%% Criterion 1: the doc names each v0.2 process-behaviour proof. Each proof in
%% the contract names a terminal state or process guarantee, so the doc must at
%% minimum carry the load-bearing run outcomes and the process-boundary line.
test_contract_doc_names_each_proof() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    %% the run outcomes the cli proofs drive toward
    [?assert(contains(Lower, Outcome))
     || Outcome <- [<<"completed">>, <<"failed">>, <<"timeout">>,
                    <<"cancelled">>]],
    %% the process-boundary guarantee (own worker, distinct pid)
    ?assert(contains(Lower, <<"distinct">>)),
    ?assert(contains(Lower, <<"pid">>)),
    %% the missing-required-field rejection proof
    ?assert(contains(Lower, <<"missing">>)),
    ?assert(contains(Lower, <<"does not resolve">>)),
    %% the external-OS-process-gone guarantee
    ?assert(contains(Lower, <<"external os process">>)).

contract_doc_names_each_proof_test() ->
    test_contract_doc_names_each_proof().

%% Criterion 1: for every proof the doc names the suite and the case that proves
%% it, so the contract is verifiable by following the map. The suites are the
%% v0.2 suites named in the issue; the cases are the ones the design maps.
test_contract_doc_names_proving_suites_and_cases() ->
    Doc = read_doc(),
    %% each v0.2 suite the contract maps proofs onto is named
    [?assert(contains(Doc, Suite))
     || Suite <- [<<"soma_tool_manifest_tests">>,
                  <<"soma_tool_registry_tests">>,
                  <<"soma_run_happy_path_SUITE">>,
                  <<"soma_cli_adapter_SUITE">>,
                  <<"soma_cli_lifecycle_SUITE">>,
                  <<"soma_cli_failure_SUITE">>]],
    %% a representative proving case from each suite is named, so the map points
    %% at a concrete function, not just a file
    [?assert(contains(Doc, Case))
     || Case <- [<<"test_normalize_rejects_missing_shared_field">>,
                 <<"test_register_tool_rejects_missing_field_name_unresolvable">>,
                 <<"test_multi_step_runs_sequentially_to_completed">>,
                 <<"test_cli_run_reaches_completed">>,
                 <<"test_cli_tool_call_has_distinct_pid">>,
                 <<"test_cli_step_event_order">>,
                 <<"test_cli_overrun_reaches_timeout">>,
                 <<"test_cli_cancel_reaches_cancelled">>,
                 <<"test_session_alive_runs_new_run_after_cli_failure">>]].

contract_doc_names_proving_suites_and_cases_test() ->
    test_contract_doc_names_proving_suites_and_cases().

%% Criterion 1: the doc names the one new gap-closing case so the contract is
%% honest about which proof had no existing coverage.
test_contract_doc_marks_the_gap_case() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    %% the doc closes the one gap with the new registry case and labels it as
    %% the gap-closing proof
    ?assert(contains(Doc, <<"test_register_tool_rejects_missing_field_name_unresolvable">>)),
    ?assert(contains(Lower, <<"gap">>)).

contract_doc_marks_the_gap_case_test() ->
    test_contract_doc_marks_the_gap_case().

