-module(soma_proposal_tests).

-include_lib("eunit/include/eunit.hrl").

%% A valid reply proposal normalizes to {ok, Proposal} carrying kind => reply.
test_reply_normalizes_ok() ->
    Raw = #{kind => reply, text => <<"hi">>},
    {ok, Proposal} = soma_proposal:normalize(Raw),
    ?assertEqual(reply, maps:get(kind, Proposal)).

reply_normalizes_ok_test() ->
    test_reply_normalizes_ok().

%% A valid run_steps proposal whose steps all pass the id+tool shape check
%% normalizes to {ok, Proposal} carrying kind => run_steps.
test_run_steps_normalizes_ok() ->
    Steps = [#{id => <<"s1">>, tool => echo}],
    Raw = #{kind => run_steps, steps => Steps},
    {ok, Proposal} = soma_proposal:normalize(Raw),
    ?assertEqual(run_steps, maps:get(kind, Proposal)).

run_steps_normalizes_ok_test() ->
    test_run_steps_normalizes_ok().

%% A valid reject proposal normalizes to {ok, Proposal} carrying kind => reject.
test_reject_normalizes_ok() ->
    Raw = #{kind => reject, reason => <<"out of scope">>},
    {ok, Proposal} = soma_proposal:normalize(Raw),
    ?assertEqual(reject, maps:get(kind, Proposal)).

reject_normalizes_ok_test() ->
    test_reject_normalizes_ok().

%% A valid ask proposal normalizes to {ok, Proposal} carrying kind => ask.
test_ask_normalizes_ok() ->
    Raw = #{kind => ask, question => <<"what now?">>},
    {ok, Proposal} = soma_proposal:normalize(Raw),
    ?assertEqual(ask, maps:get(kind, Proposal)).

ask_normalizes_ok_test() ->
    test_ask_normalizes_ok().

%% A proposal whose kind is unknown normalizes to {error, [Diagnostic]} with a
%% non-empty diagnostic list.
test_unknown_kind_errors() ->
    Raw = #{kind => some_unknown_kind, text => <<"hi">>},
    {error, Diagnostics} = soma_proposal:normalize(Raw),
    ?assert(is_list(Diagnostics)),
    ?assert(length(Diagnostics) >= 1).

unknown_kind_errors_test() ->
    test_unknown_kind_errors().

%% An actor_message proposal carrying a pid `to` but missing its required
%% `payload` field normalizes to {error, [Diagnostic]} with a non-empty
%% diagnostic list reporting the missing required field (not an unknown_kind
%% error).
test_actor_message_missing_payload_errors() ->
    Raw = #{kind => actor_message, to => self()},
    {error, Diagnostics} = soma_proposal:normalize(Raw),
    ?assert(is_list(Diagnostics)),
    ?assert(length(Diagnostics) >= 1),
    [Diagnostic | _] = Diagnostics,
    ?assertEqual(missing_required_field, maps:get(code, Diagnostic)).

actor_message_missing_payload_errors_test() ->
    test_actor_message_missing_payload_errors().

%% An actor_message proposal carrying a pid `to` and a map `payload` normalizes
%% to {ok, Proposal} carrying kind => actor_message.
test_actor_message_normalizes_ok() ->
    Raw = #{kind => actor_message, to => self(), payload => #{greeting => <<"hi">>}},
    {ok, Proposal} = soma_proposal:normalize(Raw),
    ?assertEqual(actor_message, maps:get(kind, Proposal)).

actor_message_normalizes_ok_test() ->
    test_actor_message_normalizes_ok().

%% A reply proposal missing its required text field normalizes to
%% {error, [Diagnostic]} with a non-empty diagnostic list reporting the missing
%% required field (not an unknown_kind error).
test_reply_missing_text_errors() ->
    Raw = #{kind => reply},
    {error, Diagnostics} = soma_proposal:normalize(Raw),
    ?assert(is_list(Diagnostics)),
    ?assert(length(Diagnostics) >= 1),
    [Diagnostic | _] = Diagnostics,
    ?assertEqual(missing_required_field, maps:get(code, Diagnostic)).

reply_missing_text_errors_test() ->
    test_reply_missing_text_errors().

%% An actor_message proposal carrying a map payload but missing its required
%% `to` field normalizes to {error, [Diagnostic]} with a non-empty diagnostic
%% list reporting the missing required field (not an unknown_kind error).
test_actor_message_missing_to_errors() ->
    Raw = #{kind => actor_message, payload => #{greeting => <<"hi">>}},
    {error, Diagnostics} = soma_proposal:normalize(Raw),
    ?assert(is_list(Diagnostics)),
    ?assert(length(Diagnostics) >= 1),
    [Diagnostic | _] = Diagnostics,
    ?assertEqual(missing_required_field, maps:get(code, Diagnostic)).

actor_message_missing_to_errors_test() ->
    test_actor_message_missing_to_errors().

%% A run_steps proposal whose steps list contains a step that fails the id+tool
%% step-shape check normalizes to {error, [Diagnostic]} with a non-empty
%% diagnostic list.
test_run_steps_bad_step_errors() ->
    Steps = [#{id => <<"s1">>, tool => echo}, #{id => <<"s2">>}],
    Raw = #{kind => run_steps, steps => Steps},
    {error, Diagnostics} = soma_proposal:normalize(Raw),
    ?assert(is_list(Diagnostics)),
    ?assert(length(Diagnostics) >= 1).

run_steps_bad_step_errors_test() ->
    test_run_steps_bad_step_errors().
