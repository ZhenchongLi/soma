-module(soma_service_boundary_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #244 criterion 18: service recovery delegates repeat-safety to the
%% runtime resume plan, whose descriptor-only rule is shared through one pure
%% helper. The dependency remains one-way from soma_actor to soma_runtime.
test_recovery_uses_shared_descriptor_safety_without_reverse_dependency() ->
    ServiceImports = imports(soma_service),
    PlanImports = imports(soma_run_resume_plan),
    ?assert(lists:member(
        {soma_run_resume_plan, plan, 2}, ServiceImports
    )),
    ?assert(lists:member(
        {soma_run_resume_safety, descriptor_safe, 1}, PlanImports
    )),
    ?assert(lists:member(
        {soma_tool_registry, resolve_descriptor, 1}, PlanImports
    )),

    SafetyTable =
        [{#{effect => reader, idempotent => false}, true},
         {#{effect => identity, idempotent => false}, true},
         {#{effect => state, idempotent => true}, true},
         {#{effect => state, idempotent => false}, false}],
    lists:foreach(
        fun({Descriptor, Expected}) ->
            ?assertEqual(
                Expected,
                soma_run_resume_safety:descriptor_safe(Descriptor)
            )
        end,
        SafetyTable
    ),

    RuntimeRoot = code:lib_dir(soma_runtime),
    RuntimeAppSrc = filename:join(
        [RuntimeRoot, "src", "soma_runtime.app.src"]
    ),
    {ok, [{application, soma_runtime, Properties}]} =
        file:consult(RuntimeAppSrc),
    Applications = proplists:get_value(applications, Properties),
    ?assertNot(lists:member(soma_actor, Applications)),

    RuntimeSources = filelib:wildcard(
        filename:join([RuntimeRoot, "src", "*.erl"])
    ),
    ReverseDependencies =
        [filename:basename(Path)
         || Path <- RuntimeSources, mentions_actor_app(Path)],
    ?assertEqual([], ReverseDependencies).

recovery_uses_shared_descriptor_safety_without_reverse_dependency_test() ->
    test_recovery_uses_shared_descriptor_safety_without_reverse_dependency().

imports(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    {ok, {Module, [{imports, Imports}]}} =
        beam_lib:chunks(code:which(Module), [imports]),
    Imports.

mentions_actor_app(Path) ->
    {ok, Source} = file:read_file(Path),
    binary:match(Source, <<"soma_actor">>) =/= nomatch.
