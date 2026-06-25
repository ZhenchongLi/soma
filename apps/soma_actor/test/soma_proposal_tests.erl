-module(soma_proposal_tests).

-include_lib("eunit/include/eunit.hrl").

%% A valid reply proposal normalizes to {ok, Proposal} carrying kind => reply.
test_reply_normalizes_ok() ->
    Raw = #{kind => reply, text => <<"hi">>},
    {ok, Proposal} = soma_proposal:normalize(Raw),
    ?assertEqual(reply, maps:get(kind, Proposal)).

reply_normalizes_ok_test() ->
    test_reply_normalizes_ok().
