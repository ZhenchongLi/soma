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
