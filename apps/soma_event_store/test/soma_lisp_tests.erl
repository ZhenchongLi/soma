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
