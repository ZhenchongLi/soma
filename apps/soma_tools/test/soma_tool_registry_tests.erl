-module(soma_tool_registry_tests).

-include_lib("eunit/include/eunit.hrl").

test_registry_lookup_hit() ->
    Registry = soma_tool_registry:register(#{}, echo, soma_tool_echo),
    ?assertEqual({ok, soma_tool_echo},
                 soma_tool_registry:lookup(Registry, echo)).

registry_lookup_hit_test() ->
    test_registry_lookup_hit().
