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

%% The list projection maps every live descriptor to exactly its summary
%% fields — #{name, effect, idempotent, adapter} — plus `description' only
%% when the descriptor carries one, sorted by name. Unlike catalog/1, a
%% descriptor without a description still appears (the list is the operator
%% view of every live tool, not the model-facing half).
test_list_projection_includes_summary_fields() ->
    WithDescription = #{
        name => list_described_tool,
        effect => reader,
        idempotent => true,
        timeout_ms => 5000,
        adapter => cli,
        executable => "/bin/echo",
        argv => ["hello"],
        description => <<"Uppercases text.">>
    },
    Bare = #{
        name => list_bare_tool,
        effect => state,
        idempotent => false,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo
    },
    Registry0 = soma_tool_registry:register(#{}, list_described_tool,
                                            WithDescription),
    Registry1 = soma_tool_registry:register(Registry0, list_bare_tool, Bare),
    ?assertEqual([#{name => list_bare_tool,
                    effect => state,
                    idempotent => false,
                    adapter => erlang_module},
                  #{name => list_described_tool,
                    effect => reader,
                    idempotent => true,
                    adapter => cli,
                    description => <<"Uppercases text.">>}],
                 soma_tool_registry:list_tools(Registry1)).

list_projection_includes_summary_fields_test() ->
    test_list_projection_includes_summary_fields().

%% The list projection never carries runtime internals: `module' /
%% `executable' / `argv' / `timeout_ms' from the descriptor, nor
%% process-local values (pid / port / ref) even when a stored descriptor map
%% happens to carry them. The projection constructs each entry from named
%% safe fields, so a planted internal key simply never appears.
test_list_projection_omits_internal_fields() ->
    Cli = #{
        name => scrub_cli_tool,
        effect => reader,
        idempotent => true,
        timeout_ms => 4321,
        adapter => cli,
        executable => "/bin/echo",
        argv => ["scrub-argv-value"],
        description => <<"Scrub check.">>,
        %% Process-local values planted directly in the stored map: the
        %% projection must strip these by construction, whatever the value.
        pid => self(),
        ref => make_ref(),
        port => not_a_real_port_but_the_key_is_what_matters
    },
    Emod = #{
        name => scrub_mod_tool,
        effect => state,
        idempotent => false,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo
    },
    Registry0 = soma_tool_registry:register(#{}, scrub_cli_tool, Cli),
    Registry1 = soma_tool_registry:register(Registry0, scrub_mod_tool, Emod),
    Entries = soma_tool_registry:list_tools(Registry1),
    Forbidden = [module, executable, argv, timeout_ms, pid, port, ref],
    lists:foreach(
      fun(Entry) ->
          lists:foreach(
            fun(Key) -> ?assertNot(maps:is_key(Key, Entry)) end,
            Forbidden)
      end,
      Entries),
    %% Each entry is exactly its safe summary — nothing else survived.
    ?assertEqual([#{name => scrub_cli_tool,
                    effect => reader,
                    idempotent => true,
                    adapter => cli,
                    description => <<"Scrub check.">>},
                  #{name => scrub_mod_tool,
                    effect => state,
                    idempotent => false,
                    adapter => erlang_module}],
                 Entries).

list_projection_omits_internal_fields_test() ->
    test_list_projection_omits_internal_fields().

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

%% Each text reader's live catalog entry is exactly the model-facing projection
%% of its production manifest. The typed params are pinned independently so a
%% manifest and catalog cannot drift together to the wrong public signature.
test_text_reader_catalog_entries_equal_manifest_projections() ->
    Catalog = soma_tool_registry:catalog(),
    Readers =
        [{soma_tool_text_grep,
          [#{name => <<"text">>, type => string, required => true},
           #{name => <<"pattern">>, type => string, required => true},
           #{name => <<"max_matches">>, type => integer, required => false}]},
         {soma_tool_text_head,
          [#{name => <<"text">>, type => string, required => true},
           #{name => <<"lines">>, type => integer, required => false}]}],
    lists:foreach(
      fun({Module, ExpectedTypedParams}) ->
          Projection =
              maps:with([name, description, params], Module:manifest()),
          ?assertEqual([description, name, params],
                       lists:sort(maps:keys(Projection))),
          Description = maps:get(description, Projection),
          ?assert(is_binary(Description)),
          ?assert(byte_size(Description) > 0),
          TypedParams =
              [maps:with([name, type, required], Param)
               || Param <- maps:get(params, Projection)],
          ?assertEqual(ExpectedTypedParams, TypedParams),
          Name = maps:get(name, Projection),
          Entries = [Entry || #{name := EntryName} = Entry <- Catalog,
                              EntryName =:= Name],
          ?assertEqual([Projection], Entries)
      end,
      Readers).

text_reader_catalog_entries_equal_manifest_projections_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_text_reader_catalog_entries_equal_manifest_projections())
     end}.

%% Each of the seven built-in tool manifests declares a `description', so a
%% freshly seeded registry (start_link/0 runs the same init/seed the
%% supervisor runs) lists all seven built-ins in catalog/0, every entry
%% carrying a non-empty binary description.
test_seeded_catalog_lists_all_seven_builtins() ->
    Catalog = soma_tool_registry:catalog(),
    ?assertEqual([echo, fail, file_read, file_write, sleep, text_grep,
                  text_head],
                 lists:sort([Name || #{name := Name} <- Catalog])),
    lists:foreach(
      fun(#{description := Description}) ->
          ?assert(is_binary(Description)),
          ?assert(byte_size(Description) > 0)
      end,
      Catalog).

seeded_catalog_lists_all_seven_builtins_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_seeded_catalog_lists_all_seven_builtins())
     end}.
