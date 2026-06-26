%% @doc Worker-only proofs for `soma_llm_call' that touch no actor. Criterion 1:
%% the mock returns its configured success output when invoked, and makes no
%% network call. `perform_call/1' is driven directly with a `success' directive;
%% the "no network call" half is a source-level fact -- the module opens no
%% socket -- so this proof asserts the configured output comes back.
-module(soma_llm_call_tests).

-include_lib("eunit/include/eunit.hrl").

test_mock_success_returns_configured_output() ->
    Output = <<"hello from the mock">>,
    Llm = #{directive => success, output => Output},
    ?assertEqual({ok, Output}, soma_llm_call:perform_call(Llm)).

mock_success_returns_configured_output_test() ->
    test_mock_success_returns_configured_output().

%% Criterion 8: `perform_call/1' with a `#{directive => ...}' opts map returns the
%% same result it returns today. This pins the directive path so the later
%% provider-routing clause (criterion 9) cannot silently change it.
test_perform_call_directive_unchanged() ->
    Output = #{reply => <<"unchanged">>},
    Llm = #{directive => success, output => Output},
    ?assertEqual({ok, Output}, soma_llm_call:perform_call(Llm)).

perform_call_directive_unchanged_test() ->
    test_perform_call_directive_unchanged().

%% Criterion 9: `perform_call/1' with a `#{provider => openai_compat, ...}' opts
%% map routes into `soma_llm_openai' -- it builds the request from the provider
%% config and parses a response into a `reply' proposal. This proves the routing
%% clause exists and hands off to `soma_llm_openai'. To keep the gate off the
%% socket (criterion 14), the opts carry a fixed `response' so the seam exercises
%% build-then-parse over supplied data rather than a live `httpc' request.
test_perform_call_routes_to_openai() ->
    Body = iolist_to_binary(
             json:encode(#{<<"choices">> =>
                               [#{<<"message">> =>
                                      #{<<"content">> => <<"routed reply">>}}]})),
    Llm = #{provider => openai_compat,
            base_url => <<"https://example.test/v1">>,
            api_key => <<"k">>,
            model => <<"a-model">>,
            messages => [#{role => <<"user">>, content => <<"hi">>}],
            response => {200, Body}},
    ?assertEqual({ok, #{kind => reply, text => <<"routed reply">>}},
                 soma_llm_call:perform_call(Llm)).

perform_call_routes_to_openai_test() ->
    test_perform_call_routes_to_openai().
