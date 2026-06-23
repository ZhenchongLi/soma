-module(soma_tool_registry_tests).

-include_lib("eunit/include/eunit.hrl").

test_register_lookup_returns_descriptor() ->
    Descriptor = #{adapter => erlang_module, module => soma_tool_echo},
    Registry = soma_tool_registry:register(#{}, echo, Descriptor),
    %% staged red: assert the old bare-module shape first so the assertion fires.
    ?assertEqual({ok, soma_tool_echo},
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
