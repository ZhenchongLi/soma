-module(soma_lfe_parse_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1 — valid (run ...) form parses to an internal representation.
test_valid_run_form_produces_internal_repr() ->
    Source = <<"(run (step s1 echo (args (message \"hello\")) (timeout_ms 5000)))">>,
    {ok, Result} = soma_lfe:compile(Source, #{}),
    ?assert(is_map(Result)),
    #{run := #{steps := Steps}} = Result,
    ?assertEqual(1, length(Steps)),
    [Step] = Steps,
    ?assertEqual(s1, maps:get(id, Step)),
    ?assertEqual(echo, maps:get(tool, Step)),
    ?assertEqual(#{message => <<"hello">>}, maps:get(args, Step)),
    ?assertEqual(5000, maps:get(timeout_ms, Step)).

valid_run_form_produces_internal_repr_test() ->
    test_valid_run_form_produces_internal_repr().

%% Criterion 2 — multiple top-level forms fail with a structured diagnostic.
test_multiple_top_level_forms_fail() ->
    Source = <<"(run (step s1 echo))(run (step s2 echo))">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0),
    [Diag | _] = Diags,
    ?assert(is_map(Diag)),
    ?assert(maps:is_key(message, Diag)),
    ?assert(maps:is_key(line, Diag)).

multiple_top_level_forms_fail_test() ->
    test_multiple_top_level_forms_fail().

%% Criterion 3 — a non-run top-level form fails with a structured diagnostic.
test_non_run_top_level_form_fails() ->
    Source = <<"(define foo 1)">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0),
    [Diag | _] = Diags,
    ?assert(is_map(Diag)),
    ?assert(maps:is_key(message, Diag)),
    ?assert(maps:is_key(line, Diag)).

non_run_top_level_form_fails_test() ->
    test_non_run_top_level_form_fails().

%% Criterion 4 — unknown forms inside a run or step produce structured diagnostics.
test_unknown_step_child_form_fails() ->
    Source = <<"(run (step s1 echo (unknown_form)))">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0),
    [Diag | _] = Diags,
    ?assert(is_map(Diag)),
    ?assert(maps:is_key(message, Diag)),
    ?assert(maps:is_key(line, Diag)).

unknown_step_child_form_fails_test() ->
    test_unknown_step_child_form_fails().

%% Criterion 5 — parse does not start a Soma run and does not emit runtime events.
test_parse_does_not_start_runtime() ->
    ?assertEqual(undefined, whereis(soma_sup)),
    Source = <<"(run (step s1 echo (args (message \"hello\")) (timeout_ms 5000)))">>,
    _ = soma_lfe:compile(Source, #{}),
    ?assertEqual(undefined, whereis(soma_sup)).

parse_does_not_start_runtime_test() ->
    test_parse_does_not_start_runtime().
