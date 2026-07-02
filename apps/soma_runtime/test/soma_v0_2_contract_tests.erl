-module(soma_v0_2_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/v0.2-test-contract.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 14: the v0.2 contract maps the new cli-argv-placeholder manifest
%% and runtime proofs to the exact suite/module and case that prove them.
%% This is a doc-drift guard: every name asserted here is copied from a case
%% that runs in the gate, so a renamed/deleted case surfaces as a gate failure.
test_v0_2_contract_maps_cli_argv_placeholder_proofs() ->
    Doc = read_doc(),
    %% the manifest-side proofs and their EUnit module
    ?assert(contains(Doc, <<"apps/soma_tools/test/soma_tool_manifest_tests.erl">>)),
    ?assert(contains(Doc,
        <<"test_normalize_preserves_cli_argv_placeholder_with_declared_param">>)),
    ?assert(contains(Doc,
        <<"test_normalize_rejects_cli_argv_placeholder_without_param">>)),
    %% the runtime-side proofs and their Common Test suite
    ?assert(contains(Doc, <<"soma_cli_placeholder_SUITE">>)),
    RuntimeCases =
        [<<"test_cli_argv_placeholder_from_step_replaces_doc">>,
         <<"test_cli_argv_placeholder_sends_no_trailing_input">>,
         <<"test_cli_argv_placeholder_metacharacters_are_one_arg">>,
         <<"test_cli_argv_placeholder_renders_string_integer_boolean">>,
         <<"test_cli_argv_placeholder_missing_key_fails_before_tool_started">>,
         <<"test_session_alive_runs_new_run_after_cli_placeholder_missing_key">>],
    [?assert(contains(Doc, C)) || C <- RuntimeCases],
    %% the named runtime failure reason is stated in the mapping prose
    ?assert(contains(Doc, <<"missing_cli_placeholder">>)),
    ok.

v0_2_contract_maps_cli_argv_placeholder_proofs_test() ->
    test_v0_2_contract_maps_cli_argv_placeholder_proofs().
