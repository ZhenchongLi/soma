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

test_build_request_body_omits_optional_opts() ->
    Config = #{base_url => <<"https://api.example.test/v1">>,
               api_key => <<"dummy-key">>,
               model => <<"dummy-model">>,
               messages => [#{role => <<"user">>, content => <<"hi">>}]},
    #{body := Body} = soma_llm_openai:build_request(Config),
    Decoded = json:decode(Body),
    ?assertNot(maps:is_key(<<"enable_thinking">>, Decoded)),
    ?assertNot(maps:is_key(<<"max_tokens">>, Decoded)).

build_request_body_omits_optional_opts_test() ->
    test_build_request_body_omits_optional_opts().

test_request_http_options_bounded_timeout_default_and_override() ->
    DefaultOptions = soma_llm_openai:request_http_options(#{}),
    {timeout, DefaultTimeout} = lists:keyfind(timeout, 1, DefaultOptions),
    ?assert(is_integer(DefaultTimeout)),
    ?assert(DefaultTimeout > 0),

    OverrideOptions =
        soma_llm_openai:request_http_options(#{request_timeout_ms => 1234}),
    ?assertEqual({timeout, 1234},
                 lists:keyfind(timeout, 1, OverrideOptions)).

request_http_options_bounded_timeout_default_and_override_test() ->
    test_request_http_options_bounded_timeout_default_and_override().

test_parse_response_success_to_reply() ->
    Body = <<"{\"id\":\"chatcmpl-abc123\","
             "\"object\":\"chat.completion\","
             "\"created\":1700000000,"
             "\"model\":\"dummy-model\","
             "\"choices\":[{\"index\":0,"
             "\"message\":{\"role\":\"assistant\","
             "\"content\":\"Hello from the model.\"},"
             "\"finish_reason\":\"stop\"}],"
             "\"usage\":{\"prompt_tokens\":5,"
             "\"completion_tokens\":4,\"total_tokens\":9}}">>,
    ?assertEqual({ok, #{kind => reply, text => <<"Hello from the model.">>}},
                 soma_llm_openai:parse_response({200, Body})).

parse_response_success_to_reply_test() ->
    test_parse_response_success_to_reply().

test_parse_response_bounded_errors() ->
    %% A non-200 status maps to a bounded, named error -- not a crash.
    NonOk = soma_llm_openai:parse_response({500, <<"boom">>}),
    ?assertMatch({error, _}, NonOk),
    {error, NonOkReason} = NonOk,
    ?assert(is_atom(NonOkReason) orelse is_tuple(NonOkReason)),
    %% A 200 whose body decodes but lacks the choices/message/content path is a
    %% bounded error, not a pattern-match crash.
    ErrBody = <<"{\"error\":{\"message\":\"bad request\",\"type\":\"invalid\"}}">>,
    ErrResult = soma_llm_openai:parse_response({200, ErrBody}),
    ?assertMatch({error, _}, ErrResult),
    {error, ErrReason} = ErrResult,
    ?assert(is_atom(ErrReason) orelse is_tuple(ErrReason)),
    %% A 200 with a body that is not valid JSON must be caught and bounded, not
    %% allowed to throw out of parse_response/1.
    Malformed = soma_llm_openai:parse_response({200, <<"{not json">>}),
    ?assertMatch({error, _}, Malformed),
    {error, MalformedReason} = Malformed,
    ?assert(is_atom(MalformedReason) orelse is_tuple(MalformedReason)).

parse_response_bounded_errors_test() ->
    test_parse_response_bounded_errors().

test_reply_proposal_normalizes() ->
    %% The `reply' proposal that `parse_response/1' returns on a 200 must pass
    %% `soma_proposal:normalize/1' unchanged -- i.e. the provider's reply shape is
    %% a valid proposal at the actor boundary, not something the normalize gate
    %% rejects.
    Body = <<"{\"id\":\"chatcmpl-abc123\","
             "\"object\":\"chat.completion\","
             "\"created\":1700000000,"
             "\"model\":\"dummy-model\","
             "\"choices\":[{\"index\":0,"
             "\"message\":{\"role\":\"assistant\","
             "\"content\":\"Hello from the model.\"},"
             "\"finish_reason\":\"stop\"}],"
             "\"usage\":{\"prompt_tokens\":5,"
             "\"completion_tokens\":4,\"total_tokens\":9}}">>,
    {ok, Proposal} = soma_llm_openai:parse_response({200, Body}),
    ?assertMatch({ok, _}, soma_proposal:normalize(Proposal)).

reply_proposal_normalizes_test() ->
    test_reply_proposal_normalizes().

test_app_src_lists_inets_and_ssl() ->
    %% The OpenAI provider makes real HTTPS calls via httpc, so `inets' (httpc)
    %% and `ssl' must be declared in the runtime's `applications' list to start
    %% with the release. This proof parses the app.src and asserts both are
    %% members of the applications list.
    Path = filename:join([code:lib_dir(soma_runtime), "src",
                          "soma_runtime.app.src"]),
    {ok, [{application, soma_runtime, Props}]} = file:consult(Path),
    {applications, Apps} = lists:keyfind(applications, 1, Props),
    ?assert(lists:member(inets, Apps)),
    ?assert(lists:member(ssl, Apps)).

app_src_lists_inets_and_ssl_test() ->
    test_app_src_lists_inets_and_ssl().

test_smoke_module_exports_run() ->
    %% Criterion 12: the opt-in smoke entry point exists as a `run/0' export on
    %% the `soma_llm_smoke' module. This is a structural proof only -- it loads
    %% the module and checks the export with `function_exported/3'; it never
    %% calls `run/0', so it opens no socket and needs no real key. The smoke
    %% test itself lives off the gate (a `src/' module with no `*_test'/`*_SUITE'
    %% name), so neither eunit nor ct picks it up.
    ?assertEqual({module, soma_llm_smoke}, code:ensure_loaded(soma_llm_smoke)),
    ?assert(erlang:function_exported(soma_llm_smoke, run, 0)).

smoke_module_exports_run_test() ->
    test_smoke_module_exports_run().
