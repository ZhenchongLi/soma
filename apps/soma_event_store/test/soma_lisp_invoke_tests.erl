-module(soma_lisp_invoke_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #243 criterion 4: every canonical invoke operation and optional-field
%% shape must survive the public Lisp renderer/compiler round trip unchanged.
test_canonical_invoke_maps_round_trip_through_render_and_compile() ->
    InvokeMaps =
        [#{kind => invoke,
           api_version => <<"1">>,
           request_id => <<"request-tool-empty">>,
           operation =>
               #{kind => tool,
                 step =>
                     #{id => <<"request-tool-empty">>,
                       tool => echo,
                       args => #{}}}},
         #{kind => invoke,
           api_version => <<"1">>,
           request_id => <<"request-steps-full">>,
           operation =>
               #{kind => steps,
                 steps =>
                     [#{id => read_file,
                        tool => file_read,
                        args =>
                            #{path_name => <<"input.txt">>,
                              read_mode => line_mode}},
                      #{id => echo_all,
                        tool => echo,
                        args => #{from_step => read_file},
                        timeout_ms => 500},
                      #{id => write_file,
                        tool => file_write,
                        args =>
                            #{output_path => <<"output.txt">>,
                              file_bytes => {from_step, echo_all}}}]},
           scope => [<<"file_read">>, <<"echo">>, <<"file_write">>],
           deadline_ms => 2000,
           max_output_bytes => 4096,
           correlation_id => <<"correlation-1">>,
           artifacts => [<<"artifact-read">>, <<"artifact-write">>]}],
    lists:foreach(
        fun(InvokeMap) ->
            Rendered = iolist_to_binary(soma_lisp:render(InvokeMap)),
            ?assertMatch(<<"(invoke ", _/binary>>, Rendered),
            ?assertEqual({ok, InvokeMap}, soma_lfe:compile(Rendered, #{}))
        end,
        InvokeMaps
    ).

canonical_invoke_maps_round_trip_through_render_and_compile_test() ->
    test_canonical_invoke_maps_round_trip_through_render_and_compile().

binary_from_step_reference_round_trips_through_invoke_render_test() ->
    Source =
        <<"(invoke (api-version \"1\") (request-id \"request-binary-ref\") "
          "(tool (name echo) (args (from_step \"prior\"))))">>,
    {ok, Candidate} = soma_lfe:compile(Source, #{}),
    {ok, Canonical} = soma_service_envelope:normalize(Candidate),
    RenderResult =
        try
            {ok, iolist_to_binary(soma_lisp:render(Canonical))}
        catch
            error:function_clause -> {error, renderer_function_clause}
        end,
    ?assertMatch({ok, _}, RenderResult),
    {ok, Rendered} = RenderResult,
    ?assertEqual({ok, Canonical}, soma_lfe:compile(Rendered, #{})).
