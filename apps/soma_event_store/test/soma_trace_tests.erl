-module(soma_trace_tests).

-include_lib("eunit/include/eunit.hrl").

test_timeline_one_line_per_event() ->
    Events = [
        #{event_type => 'actor.started', timestamp => 100},
        #{event_type => 'proposal.created', timestamp => 200},
        #{event_type => 'run.completed', timestamp => 300}
    ],
    Output = soma_trace:timeline(Events),
    Lines = string:split(iolist_to_binary(Output), <<"\n">>, all),
    % Filter out empty lines at the end
    NonEmptyLines = [L || L <- Lines, L =/= <<>>],
    ?assertEqual(3, length(NonEmptyLines)).

timeline_one_line_per_event_test() ->
    test_timeline_one_line_per_event().

test_timeline_orders_by_timestamp() ->
    %% Events given out of timestamp order: 300, 100, 200
    Events = [
        #{event_type => event_third,  timestamp => 300},
        #{event_type => event_first,  timestamp => 100},
        #{event_type => event_second, timestamp => 200}
    ],
    Output = soma_trace:timeline(Events),
    Lines = string:split(iolist_to_binary(Output), <<"\n">>, all),
    NonEmptyLines = [binary_to_list(L) || L <- Lines, L =/= <<>>],
    %% STAGED RED: wrong order — assert descending to see the assertion fire
    ?assertEqual(["event_third", "event_second", "event_first"], NonEmptyLines).

timeline_orders_by_timestamp_test() ->
    test_timeline_orders_by_timestamp().
