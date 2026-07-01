-module(soma_tool_registry_tests).

-include_lib("eunit/include/eunit.hrl").

test_register_lookup_returns_descriptor() ->
    Descriptor = #{adapter => erlang_module, module => soma_tool_echo},
    Registry = soma_tool_registry:register(#{}, echo, Descriptor),
    ?assertEqual({ok, Descriptor},
                 soma_tool_registry:lookup(Registry, echo)).

register_lookup_returns_descriptor_test() ->
    test_register_lookup_returns_descriptor().

test_registry_lookup_hit() ->
    Descriptor = #{adapter => erlang_module, module => soma_tool_echo},
    Registry = soma_tool_registry:register(#{}, echo, Descriptor),
    ?assertEqual({ok, Descriptor},
                 soma_tool_registry:lookup(Registry, echo)).

registry_lookup_hit_test() ->
    test_registry_lookup_hit().

test_registry_lookup_miss() ->
    ?assertEqual({error, not_found},
                 soma_tool_registry:lookup(#{}, echo)).

registry_lookup_miss_test() ->
    test_registry_lookup_miss().

test_registry_lists_names() ->
    Echo = #{adapter => erlang_module, module => soma_tool_echo},
    Sleep = #{adapter => erlang_module, module => soma_tool_sleep},
    Fail = #{adapter => erlang_module, module => soma_tool_fail},
    Registry0 = soma_tool_registry:register(#{}, echo, Echo),
    Registry1 = soma_tool_registry:register(Registry0, sleep, Sleep),
    Registry2 = soma_tool_registry:register(Registry1, fail, Fail),
    ?assertEqual(lists:sort([echo, sleep, fail]),
                 lists:sort(soma_tool_registry:names(Registry2))).

registry_lists_names_test() ->
    test_registry_lists_names().

%% A manifest missing a required field is rejected by register_tool/1 on the
%% running registry, and the tool name it carried does not resolve afterwards:
%% the registry was left unchanged, so resolve_descriptor/1 returns
%% {error, not_found}. This closes the does-not-resolve half of the second
%% v0.2 proof against the live gen_server, not just pure normalize/1.
test_register_tool_rejects_missing_field_name_unresolvable() ->
    %% Missing the required `effect' field; carries a name not in the seed.
    Manifest = #{
        name => ghost_tool,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo
    },
    ?assertMatch({error, _}, soma_tool_registry:register_tool(Manifest)),
    ?assertEqual({error, not_found},
                 soma_tool_registry:resolve_descriptor(ghost_tool)).

register_tool_rejects_missing_field_name_unresolvable_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_register_tool_rejects_missing_field_name_unresolvable())
     end}.

%% A catalog entry is exactly the model-facing half — #{name, description,
%% params} — with params defaulting to [] when the descriptor declared none.
%% Runtime internals (module / executable / argv / effect / idempotent /
%% timeout_ms) never appear in an entry.
test_catalog_entry_is_exactly_name_description_params() ->
    WithParams = #{
        name => catalog_full_tool,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo,
        description => <<"Echoes text back, params declared.">>,
        params => [#{name => <<"text">>,
                     type => string,
                     required => true,
                     doc => <<"The text to echo.">>}]
    },
    DescriptionOnly = #{
        name => catalog_minimal_tool,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo,
        description => <<"Has a description but declares no params.">>
    },
    ok = soma_tool_registry:register_tool(WithParams),
    ok = soma_tool_registry:register_tool(DescriptionOnly),
    Catalog = soma_tool_registry:catalog(),
    %% Every entry's key set is exactly [name, description, params]; the
    %% runtime-facing fields never leak into an entry.
    Forbidden = [module, executable, argv, effect, idempotent, timeout_ms],
    lists:foreach(
      fun(Entry) ->
          ?assertEqual([description, name, params],
                       lists:sort(maps:keys(Entry))),
          lists:foreach(
            fun(Key) -> ?assertNot(maps:is_key(Key, Entry)) end,
            Forbidden)
      end,
      Catalog),
    [FullEntry] = [E || E = #{name := catalog_full_tool} <- Catalog],
    [MinimalEntry] = [E || E = #{name := catalog_minimal_tool} <- Catalog],
    ?assertEqual(#{name => catalog_full_tool,
                   description => <<"Echoes text back, params declared.">>,
                   params => [#{name => <<"text">>,
                                type => string,
                                required => true,
                                doc => <<"The text to echo.">>}]},
                 FullEntry),
    ?assertEqual(#{name => catalog_minimal_tool,
                   description => <<"Has a description but declares no params.">>,
                   params => []},
                 MinimalEntry).

catalog_entry_is_exactly_name_description_params_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_catalog_entry_is_exactly_name_description_params())
     end}.

%% A registered tool whose descriptor carries no `description' (a v1
%% manifest) still resolves through resolve_descriptor/1 but is absent from
%% catalog/0: the catalog is the model-facing half, and a tool that declared
%% none has nothing to show a model.
test_tool_without_description_absent_from_catalog() ->
    V1Manifest = #{
        name => v1_only_tool,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo
    },
    ok = soma_tool_registry:register_tool(V1Manifest),
    %% The tool is registered and resolvable as a runtime descriptor...
    ?assertMatch({ok, #{name := v1_only_tool}},
                 soma_tool_registry:resolve_descriptor(v1_only_tool)),
    %% ...but appears in no catalog entry.
    Catalog = soma_tool_registry:catalog(),
    ?assertEqual([], [E || E = #{name := v1_only_tool} <- Catalog]).

%% Registering a manifest carrying the model-facing half through the live
%% register_tool/1 path makes the tool appear in catalog/0 with exactly the
%% description and params that were registered — registration flows through
%% normalize/1 into the registry map and out through the catalog unchanged.
test_register_tool_with_model_facing_fields_appears_in_catalog() ->
    Description = <<"Reverses the given text.">>,
    Params = [#{name => <<"text">>,
                type => string,
                required => true,
                doc => <<"The text to reverse.">>},
              #{name => <<"limit">>,
                type => integer,
                required => false}],
    Manifest = #{
        name => model_facing_tool,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo,
        description => Description,
        params => Params
    },
    ok = soma_tool_registry:register_tool(Manifest),
    Catalog = soma_tool_registry:catalog(),
    [Entry] = [E || E = #{name := model_facing_tool} <- Catalog],
    ?assertEqual(#{name => model_facing_tool,
                   description => Description,
                   params => Params},
                 Entry).

register_tool_with_model_facing_fields_appears_in_catalog_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_register_tool_with_model_facing_fields_appears_in_catalog())
     end}.

tool_without_description_absent_from_catalog_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_tool_without_description_absent_from_catalog())
     end}.
