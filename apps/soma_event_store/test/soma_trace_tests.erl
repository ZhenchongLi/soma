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

test_timeline_failure_reason_from_top_and_payload() ->
    %% Actor-shaped event: reason is a top-level key on the event map
    ActorEvent = #{event_type => 'actor.task.failed', timestamp => 1,
                   reason => <<"bang">>, task_id => <<"t1">>},
    %% Run-shaped event: reason lives inside payload
    RunEvent = #{event_type => 'run.failed', timestamp => 2,
                 payload => #{reason => <<"crash">>}, run_id => <<"r1">>},
    Output = soma_trace:timeline([ActorEvent, RunEvent]),
    Lines = string:split(iolist_to_binary(Output), <<"\n">>, all),
    NonEmptyLines = [binary_to_list(L) || L <- Lines, L =/= <<>>],
    ActorLine = hd(NonEmptyLines),
    RunLine = lists:nth(2, NonEmptyLines),
    %% Both lines must contain their respective reason values
    ?assertEqual(true, string:str(ActorLine, "bang") > 0),
    ?assertEqual(true, string:str(RunLine, "crash") > 0).

timeline_failure_reason_from_top_and_payload_test() ->
    test_timeline_failure_reason_from_top_and_payload().

test_render_unknown_correlation_is_empty() ->
    {ok, Store} = soma_event_store:start_link(),
    Result = soma_trace:render(Store, <<"no-such-id">>),
    %% An unknown correlation_id returns no events, so the timeline is empty
    ?assertEqual(<<>>, iolist_to_binary(Result)).

render_unknown_correlation_is_empty_test() ->
    test_render_unknown_correlation_is_empty().

test_no_dependency_on_actor_or_runtime() ->
    %% Source-level check: soma_trace.erl must not reference soma_actor or
    %% soma_runtime at all (one-way dependency: the event store layer never
    %% imports the actor or runtime apps).
    SrcDir = filename:dirname(filename:dirname(code:which(soma_trace))),
    SrcPath = filename:join([SrcDir, "src", "soma_trace.erl"]),
    {ok, Bytes} = file:read_file(SrcPath),
    Src = binary_to_list(Bytes),
    ?assertEqual(0, count_occurrences("soma_actor", Src)),
    ?assertEqual(0, count_occurrences("soma_runtime", Src)),
    %% Behavioural check: timeline/1 is callable over a plain list of maps with
    %% no runtime processes started.
    Events = [#{event_type => 'plain.event', timestamp => 1}],
    Output = soma_trace:timeline(Events),
    Lines = string:split(iolist_to_binary(Output), <<"\n">>, all),
    NonEmptyLines = [binary_to_list(L) || L <- Lines, L =/= <<>>],
    ?assertEqual(["plain.event"], NonEmptyLines).

no_dependency_on_actor_or_runtime_test() ->
    test_no_dependency_on_actor_or_runtime().

%% Count non-overlapping occurrences of Needle in Haystack.
count_occurrences(Needle, Haystack) ->
    case string:str(Haystack, Needle) of
        0 -> 0;
        Pos ->
            Rest = lists:nthtail(Pos - 1 + length(Needle), Haystack),
            1 + count_occurrences(Needle, Rest)
    end.
