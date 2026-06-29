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

test_binding_name_becomes_step_id() ->
    Source = <<
        "(task\n"
        "  (let* ((named_step (tool echo\n"
        "                        (value \"hello\"))))\n"
        "    (return named_step)))\n"
    >>,
    {ok, #{run := #{steps := [Step]}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(named_step, maps:get(id, Step)).

binding_name_becomes_step_id_test() ->
    test_binding_name_becomes_step_id().

test_tool_call_becomes_step_tool() ->
    Source = <<
        "(task\n"
        "  (let* ((read_file (tool file_read\n"
        "                         (path \"input.txt\"))))\n"
        "    (return read_file)))\n"
    >>,
    {ok, #{run := #{steps := [Step]}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(file_read, maps:get(tool, Step)).

tool_call_becomes_step_tool_test() ->
    test_tool_call_becomes_step_tool().
