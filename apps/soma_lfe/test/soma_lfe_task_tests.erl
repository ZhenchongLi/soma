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

test_literal_task_args_use_existing_coercions() ->
    Source = <<
        "(task\n"
        "  (let* ((configured (tool echo\n"
        "                         (message \"hello\")\n"
        "                         (mode dry_run)\n"
        "                         (attempts 3))))\n"
        "    (return configured)))\n"
    >>,
    {ok, #{run := #{steps := [Step]}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(
        #{message => <<"hello">>, mode => dry_run, attempts => 3},
        maps:get(args, Step)
    ).

literal_task_args_use_existing_coercions_test() ->
    test_literal_task_args_use_existing_coercions().

test_bare_from_lowers_to_from_step() ->
    Source = <<
        "(task\n"
        "  (let* ((read (tool file_read\n"
        "                  (path \"input.txt\")))\n"
        "         (echoed (tool echo\n"
        "                   (from read))))\n"
        "    (return echoed)))\n"
    >>,
    {ok, #{run := #{steps := [_ReadStep, EchoStep]}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(#{from_step => read}, maps:get(args, EchoStep)).

bare_from_lowers_to_from_step_test() ->
    test_bare_from_lowers_to_from_step().

test_field_from_lowers_to_from_step_tuple() ->
    Source = <<
        "(task\n"
        "  (let* ((read (tool file_read\n"
        "                  (path \"input.txt\")))\n"
        "         (write (tool file_write\n"
        "                   (bytes (from read)))))\n"
        "    (return write)))\n"
    >>,
    {ok, #{run := #{steps := [_ReadStep, WriteStep]}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(#{bytes => {from_step, read}}, maps:get(args, WriteStep)).

field_from_lowers_to_from_step_tuple_test() ->
    test_field_from_lowers_to_from_step_tuple().

test_timeout_ms_lowers_to_step_timeout_ms() ->
    Source = <<
        "(task\n"
        "  (let* ((wait (tool sleep\n"
        "                  (timeout-ms 250)\n"
        "                  (duration_ms 1000))))\n"
        "    (return wait)))\n"
    >>,
    {ok, #{run := #{steps := [Step]}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(250, maps:get(timeout_ms, Step)).

timeout_ms_lowers_to_step_timeout_ms_test() ->
    test_timeout_ms_lowers_to_step_timeout_ms().

test_duplicate_binding_returns_diagnostic() ->
    Source = <<
        "(task\n"
        "  (let* ((dup (tool echo\n"
        "                 (value \"one\")))\n"
        "         (dup (tool echo\n"
        "                 (value \"two\"))))\n"
        "    (return dup)))\n"
    >>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assertEqual([duplicate_binding], [maps:get(code, Diag) || Diag <- Diags]).

duplicate_binding_returns_diagnostic_test() ->
    test_duplicate_binding_returns_diagnostic().

test_forward_from_binding_returns_diagnostic() ->
    Source = <<
        "(task\n"
        "  (let* ((echoed (tool echo\n"
        "                   (from later)))\n"
        "         (later (tool echo\n"
        "                  (value \"done\"))))\n"
        "    (return echoed)))\n"
    >>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assertEqual([invalid_from_binding], [maps:get(code, Diag) || Diag <- Diags]).

forward_from_binding_returns_diagnostic_test() ->
    test_forward_from_binding_returns_diagnostic().

test_unknown_from_binding_returns_diagnostic() ->
    Source = <<
        "(task\n"
        "  (let* ((echoed (tool echo\n"
        "                   (from missing))))\n"
        "    (return echoed)))\n"
    >>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assertEqual([invalid_from_binding], [maps:get(code, Diag) || Diag <- Diags]).

unknown_from_binding_returns_diagnostic_test() ->
    test_unknown_from_binding_returns_diagnostic().

test_missing_return_returns_diagnostic() ->
    Source = <<
        "(task\n"
        "  (let* ((echoed (tool echo\n"
        "                   (value \"done\"))))))\n"
    >>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assertEqual([invalid_return], [maps:get(code, Diag) || Diag <- Diags]).

missing_return_returns_diagnostic_test() ->
    test_missing_return_returns_diagnostic().

test_unknown_return_returns_diagnostic() ->
    Source = <<
        "(task\n"
        "  (let* ((echoed (tool echo\n"
        "                   (value \"done\"))))\n"
        "    (return missing)))\n"
    >>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assertEqual([invalid_return], [maps:get(code, Diag) || Diag <- Diags]).

unknown_return_returns_diagnostic_test() ->
    test_unknown_return_returns_diagnostic().
