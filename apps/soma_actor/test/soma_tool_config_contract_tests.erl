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

%% Criterion 22 (#220): the tool-config contract maps every new `soma tool`
%% management behavior — register / list / remove / events / no-actor /
%% harness — to the exact suite and case that proves it. Same doc-drift-guard
%% shape as above: every name asserted here is copied from a case that runs
%% in the gate, so a renamed/deleted case surfaces as a gate failure.
test_tool_config_contract_maps_tool_management_proofs() ->
    Doc = read_doc(),
    %% the socket-driven suite and the pure registry unit module
    ?assert(contains(Doc, <<"soma_tool_management_SUITE">>)),
    ?assert(contains(Doc, <<"soma_tool_registry_tests">>)),
    Proofs =
        [%% register
         <<"test_register_sends_manifest_over_socket">>,
         <<"test_register_tool_resolves_before_restart">>,
         <<"test_register_writes_normalized_manifest_file">>,
         <<"test_restart_after_register_resolves_from_file">>,
         <<"test_register_invalid_manifest_returns_normalize_error">>,
         <<"test_failed_register_leaves_tools_dir_unchanged">>,
         <<"test_failed_register_leaves_registry_clean">>,
         <<"test_register_builtin_name_reserved">>,
         <<"test_register_existing_config_tool_already_registered">>,
         %% list (suite case + pure projection unit)
         <<"test_list_returns_summary_fields">>,
         <<"list_projection_includes_summary_fields_test">>,
         <<"test_list_omits_internal_fields">>,
         <<"list_projection_omits_internal_fields_test">>,
         %% remove
         <<"test_remove_config_tool_unresolved">>,
         <<"test_remove_deletes_only_owned_manifest_file">>,
         <<"test_remove_builtin_not_config_tool">>,
         <<"test_remove_never_deletes_outside_tools_dir">>,
         <<"test_restart_after_remove_stays_unresolved">>,
         %% events
         <<"test_register_appends_bounded_event">>,
         <<"test_remove_appends_bounded_event">>,
         <<"test_tool_events_omit_sensitive_fields">>,
         %% off the actor path
         <<"test_register_starts_no_actor_task">>,
         %% real-socket harness invariant
         <<"test_harness_drives_real_socket_with_temp_dirs_and_stub">>],
    lists:foreach(
        fun(Proof) ->
            ?assertEqual({Proof, mapped}, {Proof, case contains(Doc, Proof) of
                                                      true -> mapped;
                                                      false -> missing
                                                  end})
        end,
        Proofs),
    ok.

tool_config_contract_maps_tool_management_proofs_test() ->
    test_tool_config_contract_maps_tool_management_proofs().
