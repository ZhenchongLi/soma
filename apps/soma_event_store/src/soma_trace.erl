-module(soma_trace).

-export([timeline/1, render/2, render_lisp/2]).

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

%% Fetch the correlation chain, sort it by timestamp ascending, and render
%% each event as a Lisp s-expr (one per line, event order).
-spec render_lisp(Store :: pid(), CorrelationId :: term()) -> iodata().
render_lisp(Store, CorrelationId) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Sorted = lists:sort(fun(E1, E2) ->
                            maps:get(timestamp, E1, 0) =< maps:get(timestamp, E2, 0)
                        end, Events),
    [[soma_lisp:render(Event), "\n"] || Event <- Sorted].

%% Internal: format a single event as a line (string).
format_event(Event) ->
    EventType = maps:get(event_type, Event, unknown),
    Base = to_str(EventType),
    Base1 = case maps:get(task_id, Event, undefined) of
        undefined ->
            Base;
        TaskId ->
            Base ++ " task_id=" ++ to_str(TaskId)
    end,
    Base2 = case maps:get(step_id, Event, undefined) of
        undefined ->
            Base1;
        StepId ->
            Base1 ++ " step_id=" ++ to_str(StepId)
    end,
    %% Reason: check top-level key first, then fall back to payload map
    Reason = case maps:get(reason, Event, undefined) of
        undefined ->
            RawPayload = maps:get(payload, Event, #{}),
            Payload = case is_map(RawPayload) of
                true  -> RawPayload;
                false -> #{}
            end,
            maps:get(reason, Payload, undefined);
        R ->
            R
    end,
    case Reason of
        undefined ->
            Base2;
        _ ->
            Base2 ++ " reason=" ++ to_str(Reason)
    end.

%% Convert atoms, binaries, lists, or any term to a flat string.
to_str(V) when is_atom(V)   -> atom_to_list(V);
to_str(V) when is_binary(V) -> binary_to_list(V);
to_str(V) when is_list(V)   -> V;
to_str(V)                   -> lists:flatten(io_lib:format("~p", [V])).
