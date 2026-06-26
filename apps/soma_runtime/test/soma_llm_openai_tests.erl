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

test_build_request_auth_header() ->
    Config = #{base_url => <<"https://api.example.test/v1">>,
               api_key => <<"dummy-key">>,
               model => <<"dummy-model">>,
               messages => [#{role => <<"user">>, content => <<"hi">>}]},
    #{headers := Headers} = soma_llm_openai:build_request(Config),
    ?assertEqual({"Authorization", "Bearer dummy-key"},
                 lists:keyfind("Authorization", 1, Headers)).

build_request_auth_header_test() ->
    test_build_request_auth_header().

test_build_request_body_has_model_and_messages() ->
    Config = #{base_url => <<"https://api.example.test/v1">>,
               api_key => <<"dummy-key">>,
               model => <<"dummy-model">>,
               messages => [#{role => <<"user">>, content => <<"hi">>}]},
    #{body := Body} = soma_llm_openai:build_request(Config),
    Decoded = json:decode(Body),
    ?assert(is_map(Decoded)),
    ?assert(maps:is_key(<<"model">>, Decoded)),
    ?assert(maps:is_key(<<"messages">>, Decoded)).

build_request_body_has_model_and_messages_test() ->
    test_build_request_body_has_model_and_messages().

test_build_request_body_includes_optional_opts() ->
    Config = #{base_url => <<"https://api.example.test/v1">>,
               api_key => <<"dummy-key">>,
               model => <<"dummy-model">>,
               messages => [#{role => <<"user">>, content => <<"hi">>}],
               enable_thinking => false,
               max_tokens => 256},
    #{body := Body} = soma_llm_openai:build_request(Config),
    Decoded = json:decode(Body),
    ?assert(maps:is_key(<<"enable_thinking">>, Decoded)),
    ?assert(maps:is_key(<<"max_tokens">>, Decoded)).

build_request_body_includes_optional_opts_test() ->
    test_build_request_body_includes_optional_opts().
