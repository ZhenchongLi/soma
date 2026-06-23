-module(soma_tool_sleep_tests).

-include_lib("eunit/include/eunit.hrl").

test_sleep_waits_requested_ms() ->
    Ms = 50,
    Input = #{ms => Ms},
    Before = erlang:monotonic_time(millisecond),
    Result = soma_tool_sleep:invoke(Input, #{}),
    After = erlang:monotonic_time(millisecond),
    ?assertMatch({ok, _}, Result),
    ?assert((After - Before) >= Ms).

sleep_waits_requested_ms_test() ->
    test_sleep_waits_requested_ms().
