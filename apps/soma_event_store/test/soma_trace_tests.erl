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
    %% Ascending timestamp order: 100, 200, 300
    ?assertEqual(["event_first", "event_second", "event_third"], NonEmptyLines).

timeline_orders_by_timestamp_test() ->
    test_timeline_orders_by_timestamp().

test_timeline_line_names_event_type() ->
    Events = [#{event_type => 'tool.invoked', timestamp => 1}],
    Output = soma_trace:timeline(Events),
    Lines = string:split(iolist_to_binary(Output), <<"\n">>, all),
    NonEmptyLines = [binary_to_list(L) || L <- Lines, L =/= <<>>],
    Line = hd(NonEmptyLines),
    %% Each line must contain the event_type atom as a string
    ?assertEqual(true, string:str(Line, "tool.invoked") > 0).

timeline_line_names_event_type_test() ->
    test_timeline_line_names_event_type().

test_timeline_line_includes_task_id() ->
    Events = [#{event_type => 'actor.started', timestamp => 1, task_id => <<"task-abc-123">>}],
    Output = soma_trace:timeline(Events),
    Lines = string:split(iolist_to_binary(Output), <<"\n">>, all),
    NonEmptyLines = [binary_to_list(L) || L <- Lines, L =/= <<>>],
    Line = hd(NonEmptyLines),
    %% The line must contain the task_id value
    ?assertEqual(true, string:str(Line, "task-abc-123") > 0).

timeline_line_includes_task_id_test() ->
    test_timeline_line_includes_task_id().

test_timeline_line_includes_step_id() ->
    Events = [#{event_type => 'tool.invoked', timestamp => 1, step_id => <<"step-xyz-456">>}],
    Output = soma_trace:timeline(Events),
    Lines = string:split(iolist_to_binary(Output), <<"\n">>, all),
    NonEmptyLines = [binary_to_list(L) || L <- Lines, L =/= <<>>],
    Line = hd(NonEmptyLines),
    %% The line must contain the step_id value
    ?assertEqual(true, string:str(Line, "step-xyz-456") > 0).

timeline_line_includes_step_id_test() ->
    test_timeline_line_includes_step_id().
