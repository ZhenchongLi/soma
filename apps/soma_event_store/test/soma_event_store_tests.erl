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

test_by_run_filters() ->
    {ok, Pid} = soma_event_store:start_link(),
    ok = soma_event_store:append(Pid, #{run_id => run_a, event_type => a1}),
    ok = soma_event_store:append(Pid, #{run_id => run_b, event_type => b1}),
    ok = soma_event_store:append(Pid, #{run_id => run_a, event_type => a2}),
    Events = soma_event_store:by_run(Pid, run_a),
    Types = [maps:get(event_type, E) || E <- Events],
    ?assertEqual([a1, a2], Types).

by_run_filters_test() ->
    test_by_run_filters().

test_by_session_filters() ->
    {ok, Pid} = soma_event_store:start_link(),
    ok = soma_event_store:append(Pid, #{session_id => sess_a, event_type => a1}),
    ok = soma_event_store:append(Pid, #{session_id => sess_b, event_type => b1}),
    ok = soma_event_store:append(Pid, #{session_id => sess_a, event_type => a2}),
    Events = soma_event_store:by_session(Pid, sess_a),
    Types = [maps:get(event_type, E) || E <- Events],
    ?assertEqual([a1, a2], Types).

by_session_filters_test() ->
    test_by_session_filters().

test_event_has_all_eight_fields() ->
    {ok, Pid} = soma_event_store:start_link(),
    ok = soma_event_store:append(Pid, #{session_id => sess_a,
                                        run_id => run_a,
                                        event_type => 'session.started',
                                        payload => #{}}),
    [Event] = soma_event_store:all(Pid),
    Keys = lists:sort(maps:keys(Event)),
    ?assertEqual([event_id, event_type, payload, run_id,
                  session_id, step_id, timestamp, tool_call_id],
                 Keys),
    ?assertEqual(undefined, maps:get(step_id, Event)),
    ?assertEqual(undefined, maps:get(tool_call_id, Event)).

event_has_all_eight_fields_test() ->
    test_event_has_all_eight_fields().

test_event_id_unique() ->
    {ok, Pid} = soma_event_store:start_link(),
    ok = soma_event_store:append(Pid, #{event_type => same, payload => #{x => 1}}),
    ok = soma_event_store:append(Pid, #{event_type => same, payload => #{x => 1}}),
    ok = soma_event_store:append(Pid, #{event_type => other, payload => #{x => 2}}),
    Events = soma_event_store:all(Pid),
    Ids = [maps:get(event_id, E) || E <- Events],
    ?assertEqual(length(Ids), length(lists:usort(Ids))).

event_id_unique_test() ->
    test_event_id_unique().

test_timestamp_filled_when_absent() ->
    {ok, Pid} = soma_event_store:start_link(),
    ok = soma_event_store:append(Pid, #{event_type => no_ts, payload => #{}}),
    [Event] = soma_event_store:all(Pid),
    Timestamp = maps:get(timestamp, Event),
    ?assertNotEqual(undefined, Timestamp),
    ?assert(Timestamp =/= undefined).

timestamp_filled_when_absent_test() ->
    test_timestamp_filled_when_absent().

test_empty_store_returns_empty_list() ->
    {ok, Pid} = soma_event_store:start_link(),
    ?assertEqual([], soma_event_store:all(Pid)),
    ?assertEqual([], soma_event_store:by_run(Pid, some_run)),
    ?assertEqual([], soma_event_store:by_session(Pid, some_session)).

empty_store_returns_empty_list_test() ->
    test_empty_store_returns_empty_list().

test_store_survives_empty_query() ->
    {ok, Pid} = soma_event_store:start_link(),
    [] = soma_event_store:all(Pid),
    ?assertEqual(false, is_process_alive(Pid)).

store_survives_empty_query_test() ->
    test_store_survives_empty_query().
