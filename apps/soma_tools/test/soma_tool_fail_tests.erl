-module(soma_tool_fail_tests).

-include_lib("eunit/include/eunit.hrl").

test_fail_error_mode_returns_error() ->
    Input = #{mode => error, reason => boom},
    ?assertEqual({error, boom}, soma_tool_fail:invoke(Input, #{})).

fail_error_mode_returns_error_test() ->
    test_fail_error_mode_returns_error().
