-module(soma_lfe_ask_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1 — (ask (intent "...")) parses to #{ask => #{intent => <<"...">>}}.
test_ask_intent_parses_to_ask_map() ->
    Source = <<"(ask (intent \"summarize the logs\"))">>,
    Result = soma_lfe:compile(Source, #{}),
    Expected = {ok, #{ask => #{intent => <<"summarize the logs">>}}},
    ?assertEqual(Expected, Result).

ask_intent_parses_to_ask_map_test() ->
    test_ask_intent_parses_to_ask_map().
