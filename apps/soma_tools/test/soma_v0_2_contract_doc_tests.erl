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

%% Criterion 3: the built-ins-register-through-manifest + echo-end-to-end proof
%% lists and maps *both* its halves, naming the proving case for each. The
%% register-through-manifest half resolves to the seeded-registry case and the
%% echo half to the multi-step run case; both must be named so the proof is
%% verifiable down to a concrete function on each half.
test_contract_doc_maps_both_halves_of_register_and_echo_proof() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"test_registry_seeds_descriptors_from_manifests">>)),
    ?assert(contains(Doc, <<"test_multi_step_runs_sequentially_to_completed">>)).

contract_doc_maps_both_halves_of_register_and_echo_proof_test() ->
    test_contract_doc_maps_both_halves_of_register_and_echo_proof().

%% Criterion 4: the "a cli tool drives a run to completed" proof is listed and
%% mapped to its proving case, with the session → run → tool-call entry chain
%% the criterion phrases it through, and the completed outcome it drives toward.
%% Narrower than criterion 1's bare naming of the case: it pins the proof's own
%% row to its suite, case, the three-layer entry chain, and run.completed all in
%% one contiguous block, so the map points at the full path, not just the file.
test_contract_doc_maps_cli_run_reaches_completed_proof() ->
    Doc = read_doc(),
    Block = cli_completed_proof_block(Doc),
    ?assert(contains(Block, <<"soma_cli_adapter_SUITE">>)),
    ?assert(contains(Block, <<"test_cli_run_reaches_completed">>)),
    ?assert(contains(Block, <<"soma_agent_session:start_run/2">>)),
    ?assert(contains(Block, <<"soma_run">>)),
    ?assert(contains(Block, <<"soma_tool_call">>)),
    %% proof 3 drives the run to its completed terminal state
    ?assert(contains(Block, <<"run.completed">>)).

%% The proof-3 section block: from its heading up to the next "### " heading.
cli_completed_proof_block(Doc) ->
    %% match the ASCII prefix of the proof-3 heading; the heading text contains
    %% a non-ASCII em-dash that is awkward to carry safely in a source literal.
    Heading = <<"### Proof 3 ">>,
    case binary:match(Doc, Heading) of
        nomatch -> erlang:error({heading_not_found, Heading});
        {Start, _} ->
            Rest = binary:part(Doc, Start, byte_size(Doc) - Start),
            %% drop the heading line itself, then cut at the next section
            [_HeadingLine | After] = binary:split(Rest, <<"\n">>),
            AfterBin = iolist_to_binary(lists:join(<<"\n">>, After)),
            case binary:match(AfterBin, <<"### ">>) of
                nomatch -> AfterBin;
                {NextStart, _} -> binary:part(AfterBin, 0, NextStart)
            end
    end.

contract_doc_maps_cli_run_reaches_completed_proof_test() ->
    test_contract_doc_maps_cli_run_reaches_completed_proof().

%% Criterion 5: the "a cli invocation runs in its own soma_tool_call worker whose
%% pid is distinct from the soma_run process" proof is listed and mapped to its
%% proving case, with the session → run → tool-call entry chain and the
%% distinct-pid (run pid and worker pid differ) process-boundary guarantee, all
%% in one contiguous Proof 4 block.
test_contract_doc_maps_cli_distinct_pid_proof() ->
    Doc = read_doc(),
    Block = cli_distinct_pid_proof_block(Doc),
    ?assert(contains(Block, <<"soma_cli_adapter_SUITE">>)),
    ?assert(contains(Block, <<"test_cli_tool_call_has_distinct_pid">>)),
    ?assert(contains(Block, <<"soma_agent_session:start_run/2">>)),
    ?assert(contains(Block, <<"soma_run">>)),
    %% the own-worker half of the boundary: the block names the worker the cli
    %% call runs in (the soma_tool_call worker, phrased as "worker" in the block)
    ?assert(contains(Block, <<"worker">>)),
    %% the distinct-pid process-boundary guarantee: the block states the run pid
    %% and worker pid differ
    ?assert(contains(Block, <<"differ">>)).

%% The proof-4 section block: from its heading up to the next "### " heading.
cli_distinct_pid_proof_block(Doc) ->
    Heading = <<"### Proof 4 ">>,
    case binary:match(Doc, Heading) of
        nomatch -> erlang:error({heading_not_found, Heading});
        {Start, _} ->
            Rest = binary:part(Doc, Start, byte_size(Doc) - Start),
            [_HeadingLine | After] = binary:split(Rest, <<"\n">>),
            AfterBin = iolist_to_binary(lists:join(<<"\n">>, After)),
            case binary:match(AfterBin, <<"### ">>) of
                nomatch -> AfterBin;
                {NextStart, _} -> binary:part(AfterBin, 0, NextStart)
            end
    end.

contract_doc_maps_cli_distinct_pid_proof_test() ->
    test_contract_doc_maps_cli_distinct_pid_proof().

%% Criterion 6: the "a successful cli invocation emits the same event-type trail
%% as an Erlang tool" proof is listed and mapped to its proving case(s), with the
%% full event trail (tool.started, tool.succeeded, step.succeeded, then
%% run.completed) and the two-case split stated honestly: test_cli_step_event_order
%% asserts the first three in order, test_cli_run_reaches_completed asserts
%% run.completed in the same one-step cli run. The block must name both cases, all
%% four event types, the session entry, and acknowledge that no single case
%% asserts all four in one ordered chain — all in one contiguous Proof 5 block.
test_contract_doc_maps_cli_event_trail_proof() ->
    Doc = read_doc(),
    Block = cli_event_trail_proof_block(Doc),
    Lower = string:lowercase(Block),
    ?assert(contains(Block, <<"soma_cli_adapter_SUITE">>)),
    ?assert(contains(Block, <<"test_cli_step_event_order">>)),
    ?assert(contains(Block, <<"test_cli_run_reaches_completed">>)),
    ?assert(contains(Block, <<"soma_agent_session:start_run/2">>)),
    %% the full four-event trail the proof asserts the cli run emits
    ?assert(contains(Block, <<"tool.started">>)),
    ?assert(contains(Block, <<"tool.succeeded">>)),
    ?assert(contains(Block, <<"step.succeeded">>)),
    ?assert(contains(Block, <<"run.completed">>)),
    %% the two-case split stated honestly: no single case covers all four in order
    ?assert(contains(Lower, <<"no single case">>)),
    ?assert(contains(Lower, <<"two cases">>)).

%% The proof-5 section block: from its heading up to the next "### " heading.
cli_event_trail_proof_block(Doc) ->
    Heading = <<"### Proof 5 ">>,
    case binary:match(Doc, Heading) of
        nomatch -> erlang:error({heading_not_found, Heading});
        {Start, _} ->
            Rest = binary:part(Doc, Start, byte_size(Doc) - Start),
            [_HeadingLine | After] = binary:split(Rest, <<"\n">>),
            AfterBin = iolist_to_binary(lists:join(<<"\n">>, After)),
            case binary:match(AfterBin, <<"### ">>) of
                nomatch -> AfterBin;
                {NextStart, _} -> binary:part(AfterBin, 0, NextStart)
            end
    end.

contract_doc_maps_cli_event_trail_proof_test() ->
    test_contract_doc_maps_cli_event_trail_proof().

%% Criterion 7: the "a cli tool whose executable exits nonzero, and one pointed
%% at a missing/unrunnable executable, each drive the run to failed while the
%% soma_agent_session stays alive" proof is listed and mapped to its proving
%% cases. The block names the suite, all five proving cases (three failure-mode
%% cases plus the dedicated session-survival case), the session entry, the
%% failed / run.failed terminal outcome, and the session-stays-alive guarantee —
%% all in one contiguous Proof 6 block.
test_contract_doc_maps_cli_failure_proof() ->
    Doc = read_doc(),
    Block = cli_failure_proof_block(Doc),
    Lower = string:lowercase(Block),
    ?assert(contains(Block, <<"soma_cli_failure_SUITE">>)),
    %% the three failure-mode cases plus the dedicated session-survival case
    ?assert(contains(Block, <<"test_non_zero_exit_carries_status">>)),
    ?assert(contains(Block, <<"test_missing_executable_named_error">>)),
    ?assert(contains(Block, <<"test_missing_executable_reaches_run_failed_trail">>)),
    ?assert(contains(Block, <<"test_non_executable_permission_error">>)),
    ?assert(contains(Block, <<"test_session_alive_runs_new_run_after_cli_failure">>)),
    ?assert(contains(Block, <<"soma_agent_session:start_run/2">>)),
    %% the failed terminal outcome the cli failures drive toward
    ?assert(contains(Lower, <<"failed">>)),
    %% the session-stays-alive guarantee
    ?assert(contains(Lower, <<"is_process_alive">>)),
    ?assert(contains(Lower, <<"stays alive">>)).

%% The proof-6 section block: from its heading up to the next "### " heading.
cli_failure_proof_block(Doc) ->
    Heading = <<"### Proof 6 ">>,
    case binary:match(Doc, Heading) of
        nomatch -> erlang:error({heading_not_found, Heading});
        {Start, _} ->
            Rest = binary:part(Doc, Start, byte_size(Doc) - Start),
            [_HeadingLine | After] = binary:split(Rest, <<"\n">>),
            AfterBin = iolist_to_binary(lists:join(<<"\n">>, After)),
            case binary:match(AfterBin, <<"### ">>) of
                nomatch -> AfterBin;
                {NextStart, _} -> binary:part(AfterBin, 0, NextStart)
            end
    end.

contract_doc_maps_cli_failure_proof_test() ->
    test_contract_doc_maps_cli_failure_proof().

