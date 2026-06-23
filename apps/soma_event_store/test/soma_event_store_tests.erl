-module(soma_event_store_tests).

-include_lib("eunit/include/eunit.hrl").

test_all_returns_append_order() ->
    {ok, Pid} = soma_event_store:start_link(),
    ok = soma_event_store:append(Pid, #{event_type => first}),
    ok = soma_event_store:append(Pid, #{event_type => second}),
    ok = soma_event_store:append(Pid, #{event_type => third}),
    Events = soma_event_store:all(Pid),
    Types = [maps:get(event_type, E) || E <- Events],
    ?assertEqual([first, second, third], Types).

all_returns_append_order_test() ->
    test_all_returns_append_order().
