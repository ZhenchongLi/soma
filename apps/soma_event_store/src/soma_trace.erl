-module(soma_trace).

-export([timeline/1, render/2]).

%% Pure function: takes a list of events, returns iodata with one line per event.
%% Events are sorted by timestamp ascending.
-spec timeline(Events :: [map()]) -> iodata().
timeline(Events) ->
    % Sort by timestamp using a custom comparator that handles maps
    Sorted = lists:sort(fun(E1, E2) ->
                            T1 = maps:get(timestamp, E1, 0),
                            T2 = maps:get(timestamp, E2, 0),
                            T1 =< T2
                        end, Events),
    Lines = [format_event(Event) || Event <- Sorted],
    [L ++ "\n" || L <- Lines].

%% Call the event store to fetch events by correlation_id, then timeline them.
-spec render(Store :: pid(), CorrelationId :: term()) -> iodata().
render(Store, CorrelationId) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    timeline(Events).

%% Internal: format a single event as a line (string).
format_event(Event) ->
    EventType = maps:get(event_type, Event, unknown),
    Base = atom_to_list(EventType),
    Base1 = case maps:find(task_id, Event) of
        {ok, TaskId} when is_binary(TaskId) ->
            Base ++ " task_id=" ++ binary_to_list(TaskId);
        {ok, TaskId} ->
            Base ++ " task_id=" ++ TaskId;
        error ->
            Base
    end,
    Base2 = case maps:find(step_id, Event) of
        {ok, StepId} when is_binary(StepId) ->
            Base1 ++ " step_id=" ++ binary_to_list(StepId);
        {ok, StepId} ->
            Base1 ++ " step_id=" ++ StepId;
        error ->
            Base1
    end,
    %% Reason: check top-level key first, then fall back to payload map
    Reason = case maps:get(reason, Event, undefined) of
        undefined ->
            Payload = maps:get(payload, Event, #{}),
            maps:get(reason, Payload, undefined);
        R ->
            R
    end,
    case Reason of
        undefined ->
            Base2;
        Reason when is_binary(Reason) ->
            Base2 ++ " reason=" ++ binary_to_list(Reason);
        Reason ->
            Base2 ++ " reason=" ++ io_lib:format("~p", [Reason])
    end.
