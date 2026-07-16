-module(soma_parser_hardening_compat_tests).

-include_lib("eunit/include/eunit.hrl").

test_safe_reader_default_preserves_compile_maps_and_wire_round_trips() ->
    lists:foreach(
        fun({Name, Map}) ->
            Rendered = iolist_to_binary(soma_lisp:render(Map)),
            ?assertEqual(
                {Name, {ok, Map}},
                {Name, soma_lfe:compile(Rendered, #{})}
            )
        end,
        wire_round_trip_fixtures()
    ),
    lists:foreach(
        fun({Name, Source, Expected}) ->
            ?assertEqual(
                {Name, {ok, Expected}},
                {Name, soma_lfe:compile(Source, #{})}
            )
        end,
        compile_map_fixtures()
    ).

safe_reader_default_preserves_compile_maps_and_wire_round_trips_test() ->
    test_safe_reader_default_preserves_compile_maps_and_wire_round_trips().

compile_map_fixtures() ->
    [{run,
      <<"(run (step s1 echo (args (value \"hi\"))))">>,
      #{run =>
            #{steps =>
                  [#{id => s1,
                     tool => echo,
                     args => #{value => <<"hi">>}}]}}},
     {task,
      <<"(task (let* ((greet (tool echo (value \"hello\")))) "
        "(return greet)))">>,
      #{run =>
            #{steps =>
                  [#{id => greet,
                     tool => echo,
                     args => #{value => <<"hello">>}}]}}},
     {msg,
      <<"(msg (type chat) (payload \"hi\") "
        "(steps (step (id s1) (tool echo) "
        "(args (value \"hi\")))))">>,
      #{type => chat,
        payload => <<"hi">>,
        steps =>
            [#{id => s1,
               tool => echo,
               args => #{value => <<"hi">>}}]}},
     {reply_proposal,
      <<"(reply (text \"hi\"))">>,
      #{kind => reply, text => <<"hi">>}},
     {run_steps_proposal,
      <<"(run-steps (step (id s1) (tool echo) "
        "(args (value \"hi\"))))">>,
      #{kind => run_steps,
        steps =>
            [#{id => s1,
               tool => echo,
               args => #{value => <<"hi">>}}]}},
     {reject_proposal,
      <<"(reject (reason \"tool not allowed\"))">>,
      #{kind => reject, reason => <<"tool not allowed">>}},
     {invoke,
      <<"(invoke (api-version \"1\") (request-id \"request-1\") "
        "(tool (name echo) (args (value \"hello\"))))">>,
      #{kind => invoke,
        api_version => <<"1">>,
        request_id => <<"request-1">>,
        operation =>
            #{kind => tool,
              step =>
                  #{id => <<"request-1">>,
                    tool => echo,
                    args => #{value => <<"hello">>}}}}},
     {explore,
      <<"(explore (step (id inspect) (tool echo) "
        "(args (value \"hi\"))))">>,
      #{kind => explore,
        steps =>
            [#{id => inspect,
               tool => echo,
               args => #{value => <<"hi">>}}]}},
     {ask_command,
      <<"(ask (intent \"summarize the logs\"))">>,
      #{ask => #{intent => <<"summarize the logs">>}}},
     {trace_command,
      <<"(trace \"c-1\")">>,
      #{trace => #{correlation_id => <<"c-1">>}}},
     {status_command,
      <<"(status \"t-1\")">>,
      #{status => #{task_id => <<"t-1">>}}},
     {result_command,
      <<"(result \"t-1\")">>,
      #{result => #{task_id => <<"t-1">>}}},
     {watch_command,
      <<"(watch \"t-1\" (limit 20) (cursor \"c-1\"))">>,
      #{watch =>
            #{task_id => <<"t-1">>, limit => 20, cursor => <<"c-1">>}}},
     {cancel_command,
      <<"(cancel \"t-1\")">>,
      #{cancel => #{task_id => <<"t-1">>}}},
     {stop_command,
      <<"(stop)">>,
      #{stop => #{}}}].

wire_round_trip_fixtures() ->
    [{msg,
      #{type => chat,
        payload => [text, <<"hi">>],
        steps =>
            [#{id => s1,
               tool => echo,
               args => #{value => <<"hi">>}}]}},
     {invoke,
      #{kind => invoke,
        api_version => <<"1">>,
        request_id => <<"request-tool-empty">>,
        operation =>
            #{kind => tool,
              step =>
                  #{id => <<"request-tool-empty">>,
                    tool => echo,
                    args => #{}}}}},
     {explore,
      #{kind => explore,
        steps =>
            [#{id => empty_args,
               tool => echo_tool,
               args => #{}}]}}].
