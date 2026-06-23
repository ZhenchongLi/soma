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
