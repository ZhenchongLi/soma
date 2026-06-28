-module(soma_lfe_cli_9_tests).

-include_lib("eunit/include/eunit.hrl").

test_stop_compiles_to_stop_command() ->
    Source = <<"(stop)">>,
    Expected = {ok, #{stop => #{}}},
    ?assertEqual(Expected, soma_lfe:compile(Source, #{})).

stop_compiles_to_stop_command_test() ->
    test_stop_compiles_to_stop_command().

test_stop_rejects_extra_tokens() ->
    Source = <<"(stop foo)">>,
    ?assertMatch({error, _}, soma_lfe:compile(Source, #{})).

stop_rejects_extra_tokens_test() ->
    test_stop_rejects_extra_tokens().
