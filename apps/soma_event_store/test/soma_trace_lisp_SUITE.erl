-module(soma_trace_lisp_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([test_render_lisp_orders_chain_by_timestamp/1]).

all() ->
    [test_render_lisp_orders_chain_by_timestamp].

%% soma_trace:render_lisp/2 fetches a correlation chain via by_correlation/2,
%% sorts it by timestamp ascending, and renders one s-expr per event in that
%% order. Seed a live store with one shared correlation_id and out-of-order
%% timestamps; the rendered Lisp must carry each event in ascending timestamp
%% order, one s-expr per event.
test_render_lisp_orders_chain_by_timestamp(_Config) ->
    {ok, Store} = soma_event_store:start_link(),
    Corr = <<"corr-l4">>,
    %% Appended out of timestamp order: 300, 100, 200.
    ok = soma_event_store:append(Store, #{event_type => 'event.c', timestamp => 300,
                                          correlation_id => Corr}),
    ok = soma_event_store:append(Store, #{event_type => 'event.a', timestamp => 100,
                                          correlation_id => Corr}),
    ok = soma_event_store:append(Store, #{event_type => 'event.b', timestamp => 200,
                                          correlation_id => Corr}),

    Output = iolist_to_binary(soma_trace:render_lisp(Store, Corr)),

    %% One s-expr per event: three top-level event forms.
    PosA = find(Output, <<"event.a">>),
    PosB = find(Output, <<"event.b">>),
    PosC = find(Output, <<"event.c">>),
    ?assert(PosA > 0),
    ?assert(PosB > 0),
    ?assert(PosC > 0),
    %% Ascending timestamp order: a (100) before b (200) before c (300).
    ?assert(PosA < PosB),
    ?assert(PosB < PosC),
    %% Each event renders to an event-headed s-expr; three of them.
    ?assertEqual(3, count(Output, <<"(event ">>)),
    ok.

find(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch -> 0;
        {Start, _Len} -> Start + 1
    end.

count(Haystack, Needle) ->
    length(binary:matches(Haystack, Needle)).
