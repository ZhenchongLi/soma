-module(soma_tool_fail_tests).

-include_lib("eunit/include/eunit.hrl").

test_fail_error_mode_returns_error() ->
    Input = #{mode => error, reason => boom},
    ?assertEqual({error, boom}, soma_tool_fail:invoke(Input, #{})).

fail_error_mode_returns_error_test() ->
    test_fail_error_mode_returns_error().

test_fail_crash_mode_raises() ->
    Input = #{mode => crash, reason => boom},
    ?assertError(boom, soma_tool_fail:invoke(Input, #{})).

fail_crash_mode_raises_test() ->
    test_fail_crash_mode_raises().
