-module(soma_lfe_explore_tests).

-include_lib("eunit/include/eunit.hrl").

test_explore_compiles_canonical_steps_and_matches_run_steps() ->
    StepForms =
        <<"(step (id inspect) (tool echo)) "
          "(step (id read_file) (tool file_read) "
          "      (args (path \"input.txt\")) (timeout_ms 500)) "
          "(step (id echo_all) (tool echo) (args (from_step read_file))) "
          "(step (id write_file) (tool file_write) "
          "      (args (path \"output.txt\") (bytes (from_step echo_all))))">>,
    ExploreSource = <<"(explore ", StepForms/binary, ")">>,
    RunStepsSource = <<"(run-steps ", StepForms/binary, ")">>,
    ExpectedSteps =
        [#{id => inspect, tool => echo, args => #{}},
         #{id => read_file,
           tool => file_read,
           args => #{path => <<"input.txt">>},
           timeout_ms => 500},
         #{id => echo_all,
           tool => echo,
           args => #{from_step => read_file}},
         #{id => write_file,
           tool => file_write,
           args => #{path => <<"output.txt">>,
                     bytes => {from_step, echo_all}}}],

    {ok, Explore} = soma_lfe:compile(ExploreSource, #{}),
    {ok, RunSteps} = soma_lfe:compile(RunStepsSource, #{}),

    ?assertEqual(#{kind => explore, steps => ExpectedSteps}, Explore),
    ?assertEqual(ExpectedSteps, maps:get(steps, RunSteps)),
    ?assertEqual(maps:get(steps, RunSteps), maps:get(steps, Explore)).

explore_compiles_canonical_steps_and_matches_run_steps_test() ->
    test_explore_compiles_canonical_steps_and_matches_run_steps().

test_explore_compile_starts_no_processes_or_events() ->
    {module, soma_lfe} = code:ensure_loaded(soma_lfe),
    {module, soma_lfe_reader} = code:ensure_loaded(soma_lfe_reader),
    {module, soma_lfe_parser} = code:ensure_loaded(soma_lfe_parser),
    ?assertEqual(undefined, whereis(soma_sup)),
    ?assertEqual(undefined, whereis(soma_actor_sup)),
    {ok, Store} = soma_event_store:start_link(),
    try
        EventsBefore = soma_event_store:all(Store),
        Tracee = self(),
        1 = erlang:trace(Tracee, true, [procs, {tracer, Tracee}]),
        CompileResult =
            try
                soma_lfe:compile(
                    <<"(explore (step (id s1) (tool echo) "
                      "(args (value \"hi\"))))">>,
                    #{}
                )
            after
                1 = erlang:trace(Tracee, false, [procs])
            end,
        TraceDelivery = erlang:trace_delivered(Tracee),
        SpawnTraces = collect_spawn_traces(Tracee, TraceDelivery, []),

        ?assertMatch({ok, #{kind := explore, steps := [_]}}, CompileResult),
        ?assertEqual([], SpawnTraces),
        ?assertEqual(EventsBefore, soma_event_store:all(Store)),
        ?assertEqual(undefined, whereis(soma_sup)),
        ?assertEqual(undefined, whereis(soma_actor_sup))
    after
        gen_server:stop(Store)
    end.

explore_compile_starts_no_processes_or_events_test() ->
    test_explore_compile_starts_no_processes_or_events().

test_explore_and_run_steps_share_proposal_step_production() ->
    Parser = read_source("apps/soma_lfe/src/soma_lfe_parser.erl"),
    ?assertMatch(
        {match, _},
        re:run(
            Parser,
            <<"parse_explore\\(\\[explore \\| StepForms\\]\\).*?"
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
    ).

explore_and_run_steps_share_proposal_step_production_test() ->
    test_explore_and_run_steps_share_proposal_step_production().

test_explore_source_keeps_dependency_and_atom_creation_boundaries() ->
    CompilerSources =
        [read_source("apps/soma_lfe/src/soma_lfe.erl"),
         read_source("apps/soma_lfe/src/soma_lfe_parser.erl")],
    ForbiddenImports =
        [<<"soma_runtime">>, <<"soma_actor">>, <<"soma_event_store">>],
    [?assertEqual(nomatch, binary:match(Source, Import))
     || Source <- CompilerSources, Import <- ForbiddenImports],

    {ok, [{application, soma_lfe, AppProps}]} =
        file:consult("apps/soma_lfe/src/soma_lfe.app.src"),
    ?assertEqual([kernel, stdlib], proplists:get_value(applications, AppProps)),

    AtomBoundarySources =
        CompilerSources ++ [read_source("apps/soma_event_store/src/soma_lisp.erl")],
    AtomCreationBifs =
        [<<"list_to_atom(">>,
         <<"binary_to_atom(">>,
         <<"list_to_existing_atom(">>,
         <<"binary_to_existing_atom(">>],
    [?assertEqual(nomatch, binary:match(Source, Bif))
     || Source <- AtomBoundarySources, Bif <- AtomCreationBifs].

explore_source_keeps_dependency_and_atom_creation_boundaries_test() ->
    test_explore_source_keeps_dependency_and_atom_creation_boundaries().

test_empty_explore_returns_fixed_diagnostic() ->
    Expected =
        {error,
         [#{code => empty_explore,
            message => <<"explore requires at least one step">>,
            line => 0}]},

    ?assertEqual(Expected, soma_lfe:compile(<<"(explore)">>, #{})).

empty_explore_returns_fixed_diagnostic_test() ->
    test_empty_explore_returns_fixed_diagnostic().

test_malformed_explore_step_returns_fixed_diagnostic() ->
    Expected =
        {error,
         [#{code => invalid_explore_step,
            message => <<"explore contains a malformed step">>,
            line => 0}]},
    LargeValue = binary:copy(<<"x">>, 65536),
    LargeSource =
        iolist_to_binary(
            [<<"(explore (step (id incomplete) (args (payload \"">>,
             LargeValue,
             <<"\"))))">>]
        ),

    ?assertEqual(
        Expected,
        soma_lfe:compile(<<"(explore (step (id incomplete)))">>, #{})
    ),
    ?assertEqual(Expected, soma_lfe:compile(LargeSource, #{})).

malformed_explore_step_returns_fixed_diagnostic_test() ->
    test_malformed_explore_step_returns_fixed_diagnostic().

test_unknown_explore_level_form_returns_fixed_diagnostic() ->
    Expected =
        {error,
         [#{code => unknown_explore_form,
            message => <<"explore accepts only step forms">>,
            line => 0}]},
    LargeValue = binary:copy(<<"x">>, 65536),
    LargeSource =
        iolist_to_binary(
            [<<"(explore (mystery \"">>, LargeValue, <<"\"))">>]
        ),

    ?assertEqual(Expected, soma_lfe:compile(<<"(explore (mystery))">>, #{})),
    ?assertEqual(Expected, soma_lfe:compile(LargeSource, #{})),
    Results =
        [soma_lfe:compile(<<"(explore)">>, #{}),
         soma_lfe:compile(<<"(explore (step (id incomplete)))">>, #{}),
         soma_lfe:compile(<<"(explore (mystery))">>, #{})],
    Codes = [maps:get(code, Diag) || {error, [Diag]} <- Results],
    ?assertEqual(3, length(lists:usort(Codes))).

unknown_explore_level_form_returns_fixed_diagnostic_test() ->
    test_unknown_explore_level_form_returns_fixed_diagnostic().

read_source(Path) ->
    case file:read_file(Path) of
        {ok, Source} -> Source;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

collect_spawn_traces(Tracee, TraceDelivery, Acc) ->
    receive
        {trace, Tracee, spawn, Spawned, MFA} ->
            collect_spawn_traces(Tracee, TraceDelivery, [{Spawned, MFA} | Acc]);
        {trace, Tracee, _Tag, _Info} ->
            collect_spawn_traces(Tracee, TraceDelivery, Acc);
        {trace, Tracee, _Tag, _Info1, _Info2} ->
            collect_spawn_traces(Tracee, TraceDelivery, Acc);
        {trace_delivered, Tracee, TraceDelivery} ->
            lists:reverse(Acc)
    after 1000 ->
        erlang:error(trace_delivery_timeout)
    end.
