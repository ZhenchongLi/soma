-module(soma_policy_tests).

-include_lib("eunit/include/eunit.hrl").

%% A run_steps proposal whose every step tool is in the policy's allowed_tools
%% list passes the policy check, returning allow.
test_run_steps_all_tools_allowed_returns_allow() ->
    Steps = [#{id => <<"s1">>, tool => echo}, #{id => <<"s2">>, tool => sleep}],
    {ok, Proposal} = soma_proposal:normalize(#{kind => run_steps, steps => Steps}),
    Policy = #{allowed_tools => [echo, sleep]},
    ?assertEqual(allow, soma_policy:check(Proposal, Policy)).

run_steps_all_tools_allowed_returns_allow_test() ->
    test_run_steps_all_tools_allowed_returns_allow().

%% A run_steps proposal naming a tool that is not in the policy's allowed_tools
%% list fails the policy check, returning {reject, Reason}.
test_run_steps_unknown_tool_returns_reject() ->
    Steps = [#{id => <<"s1">>, tool => echo}, #{id => <<"s2">>, tool => danger}],
    {ok, Proposal} = soma_proposal:normalize(#{kind => run_steps, steps => Steps}),
    Policy = #{allowed_tools => [echo, sleep]},
    ?assertMatch({reject, _Reason}, soma_policy:check(Proposal, Policy)).

run_steps_unknown_tool_returns_reject_test() ->
    test_run_steps_unknown_tool_returns_reject().

%% A run_steps proposal is allowed for any tool when the policy is
%% #{allowed_tools => all} or carries no allowed_tools key at all.
test_run_steps_all_or_absent_allowlist_returns_allow() ->
    Steps = [#{id => <<"s1">>, tool => echo}, #{id => <<"s2">>, tool => danger}],
    {ok, Proposal} = soma_proposal:normalize(#{kind => run_steps, steps => Steps}),
    ?assertEqual(allow, soma_policy:check(Proposal, #{allowed_tools => all})),
    ?assertEqual(allow, soma_policy:check(Proposal, #{})).

run_steps_all_or_absent_allowlist_returns_allow_test() ->
    test_run_steps_all_or_absent_allowlist_returns_allow().

%% reply, reject, and ask proposals name no tool, so they pass the policy check
%% unconditionally — even under a restrictive allowlist.
test_toolless_kinds_return_allow() ->
    Policy = #{allowed_tools => [echo]},
    {ok, Reply} = soma_proposal:normalize(#{kind => reply, text => <<"hi">>}),
    {ok, Reject} = soma_proposal:normalize(#{kind => reject, reason => <<"no">>}),
    {ok, Ask} = soma_proposal:normalize(#{kind => ask, question => <<"why?">>}),
    ?assertEqual(allow, soma_policy:check(Reply, Policy)),
    ?assertEqual(allow, soma_policy:check(Reject, Policy)),
    ?assertEqual(allow, soma_policy:check(Ask, Policy)).

toolless_kinds_return_allow_test() ->
    test_toolless_kinds_return_allow().

%% An actor_message proposal carries no tool, so it passes the policy check
%% unconditionally — even under a restrictive allowlist.
test_actor_message_returns_allow() ->
    Policy = #{allowed_tools => [echo]},
    {ok, Proposal} = soma_proposal:normalize(
        #{kind => actor_message, to => self(), payload => #{body => <<"hi">>}}),
    ?assertEqual(allow, soma_policy:check(Proposal, Policy)).

actor_message_returns_allow_test() ->
    test_actor_message_returns_allow().
