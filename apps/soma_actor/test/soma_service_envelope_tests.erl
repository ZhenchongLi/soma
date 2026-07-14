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

%% Issue #243 criterion 3: every rejected invoke class has one distinct,
%% fixed-size diagnostic, including compiler-only structural failures.
test_invalid_invoke_classes_return_fixed_typed_errors() ->
    Large = binary:copy(<<"x">>, 64 * 1024),
    Base = valid_tool_candidate(),
    Classes =
        [{missing_api_version,
          [{normalizer,
            soma_service_envelope:normalize(
                maps:remove(api_version, Base#{artifacts => [<<"x">>]})
            ),
            soma_service_envelope:normalize(
                maps:remove(api_version, Base#{artifacts => [Large]})
            )}]},
         {unsupported_api_version,
          [{normalizer,
            soma_service_envelope:normalize(Base#{api_version => <<"2">>}),
            soma_service_envelope:normalize(Base#{api_version => Large})},
           {normalizer,
            soma_service_envelope:normalize(Base#{api_version => 1}),
            soma_service_envelope:normalize(
                Base#{api_version => {invalid, Large}}
            )}]},
         {missing_request_id,
          [{normalizer,
            soma_service_envelope:normalize(
                maps:remove(request_id, Base#{artifacts => [<<"x">>]})
            ),
            soma_service_envelope:normalize(
                maps:remove(request_id, Base#{artifacts => [Large]})
            )}]},
         {invalid_request_id,
          [{normalizer,
            soma_service_envelope:normalize(
                Base#{request_id => invalid_request_id}
            ),
            soma_service_envelope:normalize(
                Base#{request_id => {invalid_request_id, Large}}
            )}]},
         {duplicate_field,
          [{compiler,
            soma_lfe:compile(duplicate_request_source(<<"x">>), #{}),
            soma_lfe:compile(duplicate_request_source(Large), #{})},
           {compiler,
            soma_lfe:compile(duplicate_tool_name_source(<<"x">>), #{}),
            soma_lfe:compile(duplicate_tool_name_source(Large), #{})},
           {compiler,
            soma_lfe:compile(duplicate_operation_source(<<"x">>), #{}),
            soma_lfe:compile(duplicate_operation_source(Large), #{})}]},
         {unknown_field,
          [{compiler,
            soma_lfe:compile(unknown_field_source(<<"x">>), #{}),
            soma_lfe:compile(unknown_field_source(Large), #{})},
           {normalizer,
            soma_service_envelope:normalize(Base#{credential => <<"x">>}),
            soma_service_envelope:normalize(Base#{credential => Large})}]},
         {invalid_operation,
          [{compiler,
            soma_lfe:compile(malformed_tool_source(<<"x">>), #{}),
            soma_lfe:compile(malformed_tool_source(Large), #{})},
           {compiler,
            soma_lfe:compile(mixed_operation_source(<<"x">>), #{}),
            soma_lfe:compile(mixed_operation_source(Large), #{})},
           {normalizer,
            soma_service_envelope:normalize(invalid_operation),
            soma_service_envelope:normalize({invalid_operation, Large})},
           {normalizer,
            soma_service_envelope:normalize(
                maps:remove(operation, Base#{artifacts => [<<"x">>]})
            ),
            soma_service_envelope:normalize(
                maps:remove(operation, Base#{artifacts => [Large]})
            )},
           {normalizer,
            soma_service_envelope:normalize(
                Base#{operation => invalid_tool_operation(<<"x">>)}
            ),
            soma_service_envelope:normalize(
                Base#{operation => invalid_tool_operation(Large)}
            )}]},
         {invalid_budget,
          [{normalizer,
            soma_service_envelope:normalize(Base#{deadline_ms => 0}),
            soma_service_envelope:normalize(
                Base#{deadline_ms => {invalid, Large}}
            )},
           {normalizer,
            soma_service_envelope:normalize(Base#{max_output_bytes => false}),
            soma_service_envelope:normalize(
                Base#{max_output_bytes => {invalid, Large}}
            )}]},
         {scope_entry_too_large,
          [{normalizer,
            soma_service_envelope:normalize(
                Base#{scope => [binary:copy(<<"s">>, 256)]}
            ),
            soma_service_envelope:normalize(Base#{scope => [Large]})},
           {normalizer,
            soma_service_envelope:normalize(Base#{scope => [not_binary]}),
            soma_service_envelope:normalize(
                Base#{scope => [{not_binary, Large}]}
            )}]},
         {invalid_artifacts,
          [{normalizer,
            soma_service_envelope:normalize(Base#{artifacts => not_a_list}),
            soma_service_envelope:normalize(
                Base#{artifacts => {not_a_list, Large}}
            )},
           {normalizer,
            soma_service_envelope:normalize(Base#{artifacts => [not_binary]}),
            soma_service_envelope:normalize(
                Base#{artifacts => [{not_binary, Large}]}
            )}]},
         {invalid_correlation_id,
          [{normalizer,
            soma_service_envelope:normalize(
                Base#{correlation_id => not_binary}
            ),
            soma_service_envelope:normalize(
                Base#{correlation_id => {not_binary, Large}}
            )}]}],

    Codes = [assert_invalid_class(Code, Pairs) || {Code, Pairs} <- Classes],
    ExpectedCodes =
        [missing_api_version,
         unsupported_api_version,
         missing_request_id,
         invalid_request_id,
         duplicate_field,
         unknown_field,
         invalid_operation,
         invalid_budget,
         scope_entry_too_large,
         invalid_artifacts,
         invalid_correlation_id],
    ?assertEqual(lists:sort(ExpectedCodes), lists:sort(Codes)),
    ?assertEqual(length(Codes), length(lists:usort(Codes))).

invalid_invoke_classes_return_fixed_typed_errors_test() ->
    test_invalid_invoke_classes_return_fixed_typed_errors().

%% Issue #243 criterion 5: invoke compilation and normalization stay process-
%% and event-free, while the compile/render applications and touched sources
%% retain their dependency and atom-creation boundaries.
test_invoke_compile_normalize_boundary_is_pure() ->
    {module, soma_lfe} = code:ensure_loaded(soma_lfe),
    {module, soma_lfe_reader} = code:ensure_loaded(soma_lfe_reader),
    {module, soma_lfe_parser} = code:ensure_loaded(soma_lfe_parser),
    {module, soma_service_envelope} =
        code:ensure_loaded(soma_service_envelope),
    {ok, Store} = soma_event_store:start_link(),
    try
        ProcessesBefore = lists:sort(erlang:processes()),
        EventsBefore = soma_event_store:all(Store),
        Tracee = self(),
        1 = erlang:trace(Tracee, true, [procs, {tracer, Tracee}]),
        NormalizeResult =
            try
                {ok, Candidate} = soma_lfe:compile(
                    <<"(invoke "
                      "  (api-version \"1\") "
                      "  (request-id \"request-pure-1\") "
                      "  (tool (name echo) (args (value \"hello\"))))">>,
                    #{}
                ),
                soma_service_envelope:normalize(Candidate)
            after
                1 = erlang:trace(Tracee, false, [procs])
            end,
        TraceDelivery = erlang:trace_delivered(Tracee),
        SpawnTraces = collect_spawn_traces(Tracee, TraceDelivery, []),

        ?assertMatch(
            {ok,
             #{kind := invoke,
               request_id := <<"request-pure-1">>,
               operation := #{kind := tool}}},
            NormalizeResult
        ),
        ?assertEqual([], SpawnTraces),
        ?assertEqual(ProcessesBefore, lists:sort(erlang:processes())),
        ?assertEqual(EventsBefore, soma_event_store:all(Store)),

        {ok, [{application, soma_lfe, LfeProps}]} =
            file:consult("apps/soma_lfe/src/soma_lfe.app.src"),
        ?assertEqual(
            [kernel, stdlib],
            proplists:get_value(applications, LfeProps)
        ),
        {ok, [{application, soma_event_store, EventStoreProps}]} =
            file:consult(
                "apps/soma_event_store/src/soma_event_store.app.src"
            ),
        ?assertEqual(
            [kernel, stdlib],
            proplists:get_value(applications, EventStoreProps)
        ),

        BoundarySources =
            [read_source("apps/soma_lfe/src/soma_lfe.erl"),
             read_source("apps/soma_lfe/src/soma_lfe_parser.erl"),
             read_source(
                 "apps/soma_actor/src/soma_service_envelope.erl"
             ),
             read_source("apps/soma_event_store/src/soma_lisp.erl")],
        AtomCreationBifs =
            [<<"list_to_atom(">>,
             <<"binary_to_atom(">>,
             <<"list_to_existing_atom(">>,
             <<"binary_to_existing_atom(">>],
        [?assertEqual(nomatch, binary:match(Source, Bif))
         || Source <- BoundarySources, Bif <- AtomCreationBifs]
    after
        gen_server:stop(Store)
    end.

invoke_compile_normalize_boundary_is_pure_test() ->
    test_invoke_compile_normalize_boundary_is_pure().

assert_invalid_class(Code, Pairs) ->
    [assert_fixed_error_pair(Code, Boundary, Small, Large)
     || {Boundary, Small, Large} <- Pairs],
    Code.

assert_fixed_error_pair(Code, Boundary, Small, Large) ->
    ?assertMatch({error, [#{code := Code}]}, Small),
    ?assertMatch({error, [#{code := Code}]}, Large),
    ?assertEqual(Small, Large),
    ?assertEqual(term_to_binary(Small), term_to_binary(Large)),
    {error, [Diagnostic]} = Small,
    ExpectedKeys =
        case Boundary of
            compiler -> [code, line, message];
            normalizer -> [code, message]
        end,
    ?assertEqual(ExpectedKeys, lists:sort(maps:keys(Diagnostic))),
    case Boundary of
        compiler -> ?assertEqual(0, maps:get(line, Diagnostic));
        normalizer -> ok
    end,
    Message = maps:get(message, Diagnostic),
    ?assert(is_binary(Message)),
    ?assert(byte_size(Message) =< 128),
    ?assert(byte_size(term_to_binary(Small)) =< 256).

valid_tool_candidate() ->
    #{kind => invoke,
      api_version => <<"1">>,
      request_id => <<"request-1">>,
      operation =>
          #{kind => tool,
            step =>
                #{id => <<"request-1">>,
                  tool => echo,
                  args => #{value => <<"hello">>}}}}.

invalid_tool_operation(Rejected) ->
    #{kind => tool,
      step =>
          #{id => <<"request-1">>,
            tool => echo,
            args => #{},
            rejected => Rejected}}.

duplicate_request_source(Rejected) ->
    iolist_to_binary(
        [<<"(invoke (api-version \"1\") (request-id \"request-1\") ">>,
         <<"(request-id \"">>, Rejected, <<"\") ">>,
         <<"(tool (name echo) (args (value \"hello\"))))">>]
    ).

duplicate_tool_name_source(Rejected) ->
    iolist_to_binary(
        [<<"(invoke (api-version \"1\") (request-id \"request-1\") ">>,
         <<"(tool (name echo) (name \"">>, Rejected,
         <<"\") (args (value \"hello\"))))">>]
    ).

duplicate_operation_source(Rejected) ->
    iolist_to_binary(
        [<<"(invoke (api-version \"1\") (request-id \"request-1\") ">>,
         <<"(tool (name echo) (args (value \"hello\"))) ">>,
         <<"(tool (name echo) (args (value \"">>, Rejected,
         <<"\"))))">>]
    ).

unknown_field_source(Rejected) ->
    iolist_to_binary(
        [<<"(invoke (api-version \"1\") (request-id \"request-1\") ">>,
         <<"(tool (name echo) (args)) (credential \"">>, Rejected,
         <<"\"))">>]
    ).

malformed_tool_source(Rejected) ->
    iolist_to_binary(
        [<<"(invoke (api-version \"1\") (request-id \"request-1\") ">>,
         <<"(tool (name echo) (args \"">>, Rejected, <<"\")))">>]
    ).

mixed_operation_source(Rejected) ->
    iolist_to_binary(
        [<<"(invoke (api-version \"1\") (request-id \"request-1\") ">>,
         <<"(tool (name echo) (args)) ">>,
         <<"(steps (step (id one) (tool echo) (args (value \"">>,
         Rejected, <<"\")))))">>]
    ).

read_source(Path) ->
    case file:read_file(Path) of
        {ok, Source} -> Source;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

collect_spawn_traces(Tracee, TraceDelivery, Acc) ->
    receive
        {trace, Tracee, spawn, Spawned, MFA} ->
            collect_spawn_traces(
                Tracee,
                TraceDelivery,
                [{Spawned, MFA} | Acc]
            );
        {trace, Tracee, _Tag, _Info} ->
            collect_spawn_traces(Tracee, TraceDelivery, Acc);
        {trace, Tracee, _Tag, _Info1, _Info2} ->
            collect_spawn_traces(Tracee, TraceDelivery, Acc);
        {trace_delivered, Tracee, TraceDelivery} ->
            lists:reverse(Acc)
    after 1000 ->
        erlang:error(trace_delivery_timeout)
    end.
