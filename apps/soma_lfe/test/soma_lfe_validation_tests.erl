-module(soma_lfe_validation_tests).

-include_lib("eunit/include/eunit.hrl").

%% AC1 — duplicate step ids return a diagnostic with code => duplicate_step_id.
test_duplicate_step_id_returns_diagnostic() ->
    Source = <<"(run (step s1 echo (args (message \"a\"))) (step s1 echo (args (message \"b\"))))">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0),
    Codes = [maps:get(code, D) || D <- Diags],
    ?assert(lists:member(duplicate_step_id, Codes)).

duplicate_step_id_returns_diagnostic_test() ->
    test_duplicate_step_id_returns_diagnostic().

%% AC2 — forward from_step reference (s2 references s3 which appears after it).
test_forward_from_step_returns_diagnostic() ->
    Source = <<"(run (step s1 echo (args (message \"hi\"))) (step s2 echo (args (from_step s3))) (step s3 echo (args (message \"there\"))))">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0),
    Codes = [maps:get(code, D) || D <- Diags],
    ?assert(lists:member(invalid_from_step, Codes)).

forward_from_step_returns_diagnostic_test() ->
    test_forward_from_step_returns_diagnostic().

%% AC3 — unknown from_step reference (references a step id that doesn't exist).
test_unknown_from_step_returns_diagnostic() ->
    Source = <<"(run (step s1 echo (args (from_step nonexistent))))">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0),
    Codes = [maps:get(code, D) || D <- Diags],
    ?assert(lists:member(invalid_from_step, Codes)).

unknown_from_step_returns_diagnostic_test() ->
    test_unknown_from_step_returns_diagnostic().

%% AC4 — timeout_ms value 0 or a string returns a diagnostic with code => invalid_timeout.
test_invalid_timeout_returns_diagnostic() ->
    %% timeout_ms 0 is non-positive
    Source0 = <<"(run (step s1 echo (timeout_ms 0)))">>,
    {error, Diags0} = soma_lfe:compile(Source0, #{}),
    ?assert(is_list(Diags0)),
    Codes0 = [maps:get(code, D) || D <- Diags0],
    ?assert(lists:member(invalid_timeout, Codes0)),
    %% timeout_ms with a string value (not an integer)
    SourceStr = <<"(run (step s1 echo (timeout_ms \"fast\")))">>,
    {error, DiagsStr} = soma_lfe:compile(SourceStr, #{}),
    ?assert(is_list(DiagsStr)),
    CodesStr = [maps:get(code, D) || D <- DiagsStr],
    ?assert(lists:member(invalid_timeout, CodesStr)).

invalid_timeout_returns_diagnostic_test() ->
    test_invalid_timeout_returns_diagnostic().

%% AC5 — unknown step child form returns a diagnostic with code => unknown_form.
test_unknown_form_returns_diagnostic() ->
    Source = <<"(run (step s1 echo (frobulate)))">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0),
    Codes = [maps:get(code, D) || D <- Diags],
    ?assert(lists:member(unknown_form, Codes)).

unknown_form_returns_diagnostic_test() ->
    test_unknown_form_returns_diagnostic().

%% AC6 — two steps each with distinct errors produce >= 2 diagnostics.
test_multiple_diagnostics_collected() ->
    %% step s1 has an unknown form; step s2 has timeout_ms 0
    Source = <<"(run (step s1 echo (frobulate)) (step s2 echo (timeout_ms 0)))">>,
    {error, Diags} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) >= 2).

multiple_diagnostics_collected_test() ->
    test_multiple_diagnostics_collected().

%% AC7 — invalid DSL does not start soma_sup.
test_invalid_dsl_does_not_start_run() ->
    ?assertEqual(undefined, whereis(soma_sup)),
    Source = <<"(run (step s1 echo (frobulate)))">>,
    {error, _} = soma_lfe:compile(Source, #{}),
    ?assertEqual(undefined, whereis(soma_sup)).

invalid_dsl_does_not_start_run_test() ->
    test_invalid_dsl_does_not_start_run().
