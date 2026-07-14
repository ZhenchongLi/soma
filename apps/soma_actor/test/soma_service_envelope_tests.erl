-module(soma_service_envelope_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #243 criterion 1: the locked tool invoke form must compile through the
%% public Lisp edge and normalize into the exact service-envelope allowlist.
test_valid_tool_invoke_compiles_and_normalizes() ->
    Source =
        <<"(invoke\n"
          "  (api-version \"1\")\n"
          "  (request-id \"request-1\")\n"
          "  (tool (name echo) (args (value \"hello\")))\n"
          "  (scope \"echo\")\n"
          "  (deadline-ms 2000)\n"
          "  (max-output-bytes 4096)\n"
          "  (correlation-id \"correlation-1\")\n"
          "  (artifacts \"artifact-1\"))">>,
    {ok, Candidate} = soma_lfe:compile(Source, #{}),
    {ok, Envelope} = soma_service_envelope:normalize(Candidate),
    Expected =
        #{kind => invoke,
          api_version => <<"1">>,
          request_id => <<"request-1">>,
          operation =>
              #{kind => tool,
                step =>
                    #{id => <<"request-1">>,
                      tool => echo,
                      args => #{value => <<"hello">>}}},
          scope => [<<"echo">>],
          deadline_ms => 2000,
          max_output_bytes => 4096,
          correlation_id => <<"correlation-1">>,
          artifacts => [<<"artifact-1">>]},
    ?assertEqual(Expected, Envelope),
    ?assertEqual(
        lists:sort([kind, api_version, request_id, operation, scope,
                    deadline_ms, max_output_bytes, correlation_id, artifacts]),
        lists:sort(maps:keys(Envelope))
    ).

valid_tool_invoke_compiles_and_normalizes_test() ->
    test_valid_tool_invoke_compiles_and_normalizes().

%% Issue #243 criterion 2: invoke and run-steps must use one private parser
%% production and yield byte-identical, source-ordered canonical step lists.
test_valid_steps_invoke_matches_run_steps_production() ->
    StepForms =
        <<"(step (id read_file) (tool file_read) "
          "      (args (path \"input.txt\"))) "
          "(step (id echo_all) (tool echo) "
          "      (args (from_step read_file)) (timeout_ms 500))">>,
    InvokeSource =
        <<"(invoke "
          "  (api-version \"1\") "
          "  (request-id \"request-steps-1\") "
          "  (steps ", StepForms/binary, "))">>,
    RunStepsSource = <<"(run-steps ", StepForms/binary, ")">>,
    ExpectedSteps =
        [#{id => read_file,
           tool => file_read,
           args => #{path => <<"input.txt">>}},
         #{id => echo_all,
           tool => echo,
           args => #{from_step => read_file},
           timeout_ms => 500}],

    {ok, InvokeCandidate} = soma_lfe:compile(InvokeSource, #{}),
    {ok, Envelope} = soma_service_envelope:normalize(InvokeCandidate),
    {ok, #{kind := run_steps, steps := RunSteps}} =
        soma_lfe:compile(RunStepsSource, #{}),
    #{operation := #{kind := steps, steps := InvokeSteps}} = Envelope,

    ?assertEqual(ExpectedSteps, InvokeSteps),
    ?assertEqual(term_to_binary(RunSteps), term_to_binary(InvokeSteps)),

    Parser = read_source("apps/soma_lfe/src/soma_lfe_parser.erl"),
    ?assertMatch(
        {match, _},
        re:run(
            Parser,
            <<"parse_invoke_fields\\(\\[\\[steps \\| StepForms\\] \\| Rest\\], Acc\\).*?"
              "parse_proposal_steps\\(StepForms\\)">>,
            [dotall]
        )
    ),
    ?assertMatch(
        {match, _},
        re:run(
            Parser,
            <<"parse_proposal\\(\\['run-steps' \\| StepForms\\]\\).*?"
              "parse_proposal_steps\\(StepForms\\)">>,
            [dotall]
        )
    ),
    ?assertNot(erlang:function_exported(
        soma_lfe_parser,
        parse_proposal_steps,
        1
    )).

valid_steps_invoke_matches_run_steps_production_test() ->
    test_valid_steps_invoke_matches_run_steps_production().

read_source(Path) ->
    case file:read_file(Path) of
        {ok, Source} -> Source;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.
