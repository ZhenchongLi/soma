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

test_render_result_map_with_task_id_emits_task_id_subform() ->
    %% A result map carrying `task_id' renders a `(task-id ...)' sub-form inside
    %% `(result ...)', placed after `status' and before `correlation-id'.
    ResultMap = #{
        status => completed,
        outputs => #{s1 => #{value => <<"hi">>}},
        task_id => <<"t-9">>,
        correlation_id => <<"c-7">>
    },
    Rendered = iolist_to_binary(soma_lisp:render(ResultMap)),
    Expected = <<"(result (status completed) (task-id \"t-9\") "
                 "(outputs ((s1 (value \"hi\")))) (correlation-id \"c-7\"))">>,
    ?assertEqual(Expected, Rendered).

render_result_map_with_task_id_emits_task_id_subform_test() ->
    test_render_result_map_with_task_id_emits_task_id_subform().

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

test_msg_envelope_round_trips_through_render() ->
    %% The criterion's (msg ...) shape, with the parser-required (payload ...)
    %% field added so the seed parse succeeds. Parse -> render -> re-parse must
    %% land on a term equal to the original parsed envelope: the renderer is the
    %% exact inverse of the parser for the (msg ...) shape.
    Source = <<"(msg (type chat) (payload (text \"hi\")) "
               "(steps (step (id s1) (tool echo) (args (value \"hi\")))))">>,
    {ok, Envelope} = soma_lfe:compile(Source, #{}),
    Rendered = iolist_to_binary(soma_lisp:render(Envelope)),
    ?assertEqual({ok, Envelope}, soma_lfe:compile(Rendered, #{})).

msg_envelope_round_trips_through_render_test() ->
    test_msg_envelope_round_trips_through_render().

test_render_pid_becomes_quoted_string() ->
    Map = #{pid => self()},
    Rendered = iolist_to_binary(soma_lisp:render(Map)),
    %% A pid has no s-expr form, so it renders as a double-quoted string
    %% (the `io_lib:format("~p", ...)' text of the pid) and never crashes.
    PidText = iolist_to_binary(io_lib:format("~p", [self()])),
    Expected = iolist_to_binary(["(pid \"", PidText, "\")"]),
    ?assertEqual(Expected, Rendered).

render_pid_becomes_quoted_string_test() ->
    test_render_pid_becomes_quoted_string().
