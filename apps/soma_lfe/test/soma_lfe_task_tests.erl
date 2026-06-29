-module(soma_lfe_task_tests).

-include_lib("eunit/include/eunit.hrl").

test_task_compiles_to_run_steps() ->
    Source = <<
        "(task\n"
        "  (let* ((greet (tool echo\n"
        "                   (value \"hello\"))))\n"
        "    (return greet)))\n"
    >>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(
        [
            #{id => greet, tool => echo, args => #{value => <<"hello">>}}
        ],
        Steps
    ).

task_compiles_to_run_steps_test() ->
    test_task_compiles_to_run_steps().

test_let_star_bindings_preserve_order() ->
    Source = <<
        "(task\n"
        "  (let* ((first (tool echo\n"
        "                    (value \"one\")))\n"
        "         (second (tool echo\n"
        "                     (value \"two\")))\n"
        "         (third (tool echo\n"
        "                    (value \"three\"))))\n"
        "    (return third)))\n"
    >>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual([first, second, third], [maps:get(id, Step) || Step <- Steps]).

let_star_bindings_preserve_order_test() ->
    test_let_star_bindings_preserve_order().
