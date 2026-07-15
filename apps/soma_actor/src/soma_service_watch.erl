%% @doc Cursor codec and page selection for the service event watch API.
-module(soma_service_watch).

-export([page/4]).

-define(CURSOR_TAG, soma_service_watch_cursor_v1).
-define(MAX_CURSOR_BYTES, 4096).

page(Events, Cursor, Limit, ServicePageEvents)
  when is_list(Events),
       is_integer(Limit), Limit > 0,
       is_integer(ServicePageEvents), ServicePageEvents > 0 ->
    case events_after_cursor(Events, Cursor) of
        {ok, RemainingEvents} ->
            PageLimit = erlang:min(Limit, ServicePageEvents),
            PageEvents = lists:sublist(RemainingEvents, PageLimit),
            {ok, #{events => PageEvents,
                   cursor => next_cursor(PageEvents, Cursor)}};
        {error, invalid_cursor} = Error ->
            Error
    end;
page(_Events, _Cursor, _Limit, _ServicePageEvents) ->
    {error, invalid_watch}.

events_after_cursor(Events, undefined) ->
    {ok, Events};
events_after_cursor(Events, Cursor) ->
    case decode_cursor(Cursor) of
        {ok, EventId} ->
            split_after_event(EventId, Events);
        {error, invalid_cursor} = Error ->
            Error
    end.

split_after_event(_EventId, []) ->
    {error, invalid_cursor};
split_after_event(EventId, [Event | Events]) ->
    case maps:find(event_id, Event) of
        {ok, EventId} ->
            {ok, Events};
        _Other ->
            split_after_event(EventId, Events)
    end.

next_cursor([], Cursor) ->
    Cursor;
next_cursor(PageEvents, _Cursor) ->
    LastEvent = lists:last(PageEvents),
    encode_cursor(maps:get(event_id, LastEvent)).

encode_cursor(EventId) ->
    base64:encode(
      term_to_binary({?CURSOR_TAG, EventId}, [deterministic])).

decode_cursor(Cursor)
  when is_binary(Cursor),
       byte_size(Cursor) > 0,
       byte_size(Cursor) =< ?MAX_CURSOR_BYTES ->
    try binary_to_term(base64:decode(Cursor), [safe]) of
        {?CURSOR_TAG, EventId} when is_binary(EventId) ->
            {ok, EventId};
        _InvalidTerm ->
            {error, invalid_cursor}
    catch
        error:_DecodeError ->
            {error, invalid_cursor}
    end;
decode_cursor(_Cursor) ->
    {error, invalid_cursor}.
