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
