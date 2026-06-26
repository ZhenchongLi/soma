-module(soma_lisp_tests).

-include_lib("eunit/include/eunit.hrl").

test_render_result_map_produces_fixed_sexpr() ->
    ResultMap = #{
        status => completed,
        outputs => #{s1 => #{value => <<"hi">>}},
        correlation_id => <<"c-7">>
    },
    Rendered = iolist_to_binary(soma_lisp:render(ResultMap)),
    Expected = <<"(result (status completed) (outputs ((s1 (value \"hi\")))) (correlation-id \"c-7\"))">>,
    ?assertEqual(Expected, Rendered).

render_result_map_produces_fixed_sexpr_test() ->
    test_render_result_map_produces_fixed_sexpr().

test_render_event_map_carries_fields() ->
    EventMap = #{
        event_type => llm_started,
        task_id => <<"t-1">>,
        step_id => <<"s1">>
    },
    Rendered = iolist_to_binary(soma_lisp:render(EventMap)),
    %% An event map renders with an `event' head, and its sub-forms carry the
    %% event's fields.
    ?assertMatch(<<"(event ", _/binary>>, Rendered),
    ?assert(binary:match(Rendered, <<"(event-type llm-started)">>) =/= nomatch),
    ?assert(binary:match(Rendered, <<"(task-id \"t-1\")">>) =/= nomatch),
    ?assert(binary:match(Rendered, <<"(step-id \"s1\")">>) =/= nomatch).

render_event_map_carries_fields_test() ->
    test_render_event_map_carries_fields().
