-module(soma_tool_registry_tests).

-include_lib("eunit/include/eunit.hrl").

test_registry_lookup_hit() ->
    Registry = soma_tool_registry:register(#{}, echo, soma_tool_echo),
    ?assertEqual({ok, soma_tool_echo},
                 soma_tool_registry:lookup(Registry, echo)).

registry_lookup_hit_test() ->
    test_registry_lookup_hit().

test_registry_lookup_miss() ->
    ?assertEqual({error, not_found},
                 soma_tool_registry:lookup(#{}, echo)).

registry_lookup_miss_test() ->
    test_registry_lookup_miss().

test_registry_lists_names() ->
    Registry0 = soma_tool_registry:register(#{}, echo, soma_tool_echo),
    Registry1 = soma_tool_registry:register(Registry0, sleep, soma_tool_sleep),
    Registry2 = soma_tool_registry:register(Registry1, fail, soma_tool_fail),
    ?assertEqual(lists:sort([echo, sleep, fail]),
                 lists:sort(soma_tool_registry:names(Registry2))).

registry_lists_names_test() ->
    test_registry_lists_names().
