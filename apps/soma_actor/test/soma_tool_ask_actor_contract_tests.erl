-module(soma_tool_ask_actor_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/tool-ask-actor-test-contract.md").

%% Issue #219 criterion 8: `docs/contracts/tool-ask-actor-test-contract.md`
%% gains a #219 section that maps each of the seven issue #219 proofs (the
%% ask_actor message shorthand, reply unwrap, invalid-input rejection, and
%% real-provider/planning system_prompt ordering behaviors) to its test case.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

test_doc_names_issue_219_section_and_cases() ->
    Doc = read_doc(),
    ?assert(byte_size(Doc) > 0),
    %% The #219 proof section marker
    ?assert(contains(Doc, <<"Issue #219">>)),
    %% The two modules that hold the seven new cases
    ?assert(contains(Doc, <<"soma_tool_ask_actor_SUITE">>)),
    ?assert(contains(Doc, <<"soma_actor_call_opts_tests">>)),
    %% The five ask_actor shorthand/reply-unwrap/rejection cases
    ?assert(contains(Doc, <<"ask_actor_shorthand_file_read_to_file_write_writes_reply_text">>)),
    ?assert(contains(Doc, <<"ask_actor_shorthand_uses_actor_mock_model_config_no_socket">>)),
    ?assert(contains(Doc, <<"ask_actor_shorthand_non_reply_result_unchanged">>)),
    ?assert(contains(Doc, <<"ask_actor_message_and_envelope_rejected">>)),
    ?assert(contains(Doc, <<"ask_actor_shorthand_non_binary_message_rejected">>)),
    %% The two system_prompt-ordering cases
    ?assert(contains(Doc, <<"real_provider_system_prompt_precedes_user_message_test">>)),
    ?assert(contains(Doc, <<"planning_system_prompt_orders_custom_then_planning_then_user_test_">>)).

issue_219_contract_names_all_proofs_test() ->
    test_doc_names_issue_219_section_and_cases().
