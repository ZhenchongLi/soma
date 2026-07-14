-module(soma_lisp_explore_tests).

-include_lib("eunit/include/eunit.hrl").

test_canonical_explore_maps_round_trip_through_render_and_compile() ->
    ExploreMaps =
        [#{kind => explore,
           steps =>
               [#{id => empty_args,
                  tool => echo_tool,
                  args => #{}}]},
         #{kind => explore,
           steps =>
               [#{id => read_file,
                  tool => file_read,
                  args => #{path_name => <<"input.txt">>, read_mode => line_mode}},
                #{id => echo_all,
                  tool => echo_tool,
                  args => #{from_step => read_file},
                  timeout_ms => 500},
                #{id => write_file,
                  tool => file_write,
                  args => #{output_path => <<"output.txt">>,
                            file_bytes => {from_step, echo_all}}}]}],
    lists:foreach(
        fun(ExploreMap) ->
            Rendered = iolist_to_binary(soma_lisp:render(ExploreMap)),
            ?assertMatch(<<"(explore ", _/binary>>, Rendered),
            ?assertEqual({ok, ExploreMap}, soma_lfe:compile(Rendered, #{}))
        end,
        ExploreMaps
    ).

canonical_explore_maps_round_trip_through_render_and_compile_test() ->
    test_canonical_explore_maps_round_trip_through_render_and_compile().
