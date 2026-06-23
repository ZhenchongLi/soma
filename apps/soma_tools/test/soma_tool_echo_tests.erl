-module(soma_tool_echo_tests).

-include_lib("eunit/include/eunit.hrl").

test_echo_returns_input() ->
    Input = #{message => <<"hello">>},
    ?assertEqual({ok, Input}, soma_tool_echo:invoke(Input, #{})).

echo_returns_input_test() ->
    test_echo_returns_input().
