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

%% Criterion 2 — (ask ...) with no (intent ...) is a parse error, not a
%% malformed ok map.
test_ask_without_intent_returns_error() ->
    Source = <<"(ask)">>,
    Result = soma_lfe:compile(Source, #{}),
    ?assertMatch({error, [_ | _]}, Result).

ask_without_intent_returns_error_test() ->
    test_ask_without_intent_returns_error().

%% Criterion 3 — (allow ...), (budget-llm N) and (budget-steps N) sub-forms
%% parse into a tool_policy allowlist and a budget map.
test_ask_allow_and_budget_parse() ->
    Source = <<"(ask (intent \"x\") (allow echo file_read) (budget-llm 3) (budget-steps 5))">>,
    Result = soma_lfe:compile(Source, #{}),
    Expected = {ok, #{ask => #{intent => <<"x">>,
                               tool_policy => #{allowed_tools => [echo, file_read]},
                               budget => #{max_llm_calls => 3, max_steps => 5}}}},
    ?assertEqual(Expected, Result).

ask_allow_and_budget_parse_test() ->
    test_ask_allow_and_budget_parse().
