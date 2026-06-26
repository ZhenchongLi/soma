%% @doc Pure-function proofs for `soma_llm_openai'. Criterion 1: `build_request/1'
%% returns the POST url `{base_url}/chat/completions' for a fixed dummy config.
%% The function builds an HTTP request and sends nothing, so this proof opens no
%% socket -- it asserts the url field of the returned request.
-module(soma_llm_openai_tests).

-include_lib("eunit/include/eunit.hrl").

test_build_request_url() ->
    Config = #{base_url => <<"https://api.example.test/v1">>,
               api_key => <<"dummy-key">>,
               model => <<"dummy-model">>,
               messages => [#{role => <<"user">>, content => <<"hi">>}]},
    #{url := Url} = soma_llm_openai:build_request(Config),
    ?assertEqual(<<"https://api.example.test/v1/chat/completions">>, Url).

build_request_url_test() ->
    test_build_request_url().
