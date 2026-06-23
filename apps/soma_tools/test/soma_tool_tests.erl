-module(soma_tool_tests).

-include_lib("eunit/include/eunit.hrl").

test_behaviour_declares_callbacks() ->
    Callbacks = soma_tool:behaviour_info(callbacks),
    ?assert(lists:member({describe, 0}, Callbacks)),
    ?assert(lists:member({invoke, 2}, Callbacks)).

behaviour_declares_callbacks_test() ->
    test_behaviour_declares_callbacks().
