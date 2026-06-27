-module(soma_lfe_cli_4_tests).

-include_lib("eunit/include/eunit.hrl").

test_cancel_compiles_to_cancel_command() ->
    Source = <<"(cancel \"task-id\")">>,
    Expected = {ok, #{cancel => #{task_id => <<"task-id">>}}},
    ?assertEqual(Expected, soma_lfe:compile(Source, #{})).

cancel_compiles_to_cancel_command_test() ->
    test_cancel_compiles_to_cancel_command().
