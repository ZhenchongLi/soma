-module(soma_tool_tests).

-include_lib("eunit/include/eunit.hrl").

test_behaviour_declares_callbacks() ->
    Callbacks = soma_tool:behaviour_info(callbacks),
    ?assert(lists:member({describe, 0}, Callbacks)),
    ?assert(lists:member({invoke, 2}, Callbacks)).

behaviour_declares_callbacks_test() ->
    test_behaviour_declares_callbacks().

test_describe_has_required_keys() ->
    Modules = [soma_tool_echo, soma_tool_sleep, soma_tool_fail,
               soma_tool_file_read, soma_tool_file_write],
    RequiredKeys = [name, effect, idempotent, timeout_ms],
    ValidEffects = [identity, reader, state],
    lists:foreach(
        fun(Module) ->
            Spec = Module:describe(),
            lists:foreach(
                fun(Key) ->
                    ?assert(maps:is_key(Key, Spec))
                end, RequiredKeys),
            ?assert(lists:member(maps:get(effect, Spec), ValidEffects))
        end, Modules).

describe_has_required_keys_test() ->
    test_describe_has_required_keys().
