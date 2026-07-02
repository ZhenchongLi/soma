-module(soma_tool_config_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/tool-config-test-contract.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 15 (#218): the tool-config contract maps the two new
%% config-loader cli-argv-placeholder proofs to their exact suite and cases.
%% This is a doc-drift guard: every name asserted here is copied from a case
%% that runs in the gate, so a renamed/deleted case surfaces as a gate failure.
test_tool_config_contract_maps_cli_argv_placeholder_proofs() ->
    Doc = read_doc(),
    %% the config-loader suite that proves both new behaviours
    ?assert(contains(Doc, <<"soma_tool_config_SUITE">>)),
    %% the two new config-loader proofs
    ?assert(contains(Doc,
        <<"test_load_dir_registers_cli_tool_with_argv_placeholders">>)),
    ?assert(contains(Doc,
        <<"test_load_dir_skips_cli_tool_with_unknown_argv_placeholder">>)),
    %% the named loader skip reason is stated in the mapping prose
    ?assert(contains(Doc, <<"unknown_argv_placeholder">>)),
    ok.

tool_config_contract_maps_cli_argv_placeholder_proofs_test() ->
    test_tool_config_contract_maps_cli_argv_placeholder_proofs().
