-module(soma_actor_call_opts_tests).

-include_lib("eunit/include/eunit.hrl").

%% A real-provider model_config (#{provider => openai_compat, base_url, model})
%% builds call opts carrying provider => openai_compat together with that
%% base_url and model -- the keys soma_llm_call:perform_call/1 routes on.
test_real_provider_model_config_builds_routing_opts() ->
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>},
    Envelope = #{payload => #{prompt => <<"hello">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    ?assertEqual(openai_compat, maps:get(provider, Opts)),
    ?assertEqual(<<"https://api.example.test/v1">>, maps:get(base_url, Opts)),
    ?assertEqual(<<"deepseek-v4">>, maps:get(model, Opts)).

real_provider_model_config_builds_routing_opts_test() ->
    test_real_provider_model_config_builds_routing_opts().

%% A real-provider model_config plus an envelope whose payload carries a prompt
%% builds opts whose `messages' is a non-empty list holding that prompt as a
%% user message -- so the real provider has something to send.
test_real_provider_opts_carry_prompt_as_user_message() ->
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>},
    Envelope = #{payload => #{prompt => <<"what is soma?">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    Messages = maps:get(messages, Opts),
    ?assert(is_list(Messages)),
    ?assertNotEqual([], Messages),
    ?assertEqual([#{role => <<"user">>, content => <<"what is soma?">>}],
                 Messages).

real_provider_opts_carry_prompt_as_user_message_test() ->
    test_real_provider_opts_carry_prompt_as_user_message().

%% A model_config that is empty or carries a `directive' (the v0.5 mock default)
%% is not a real-provider config: the builder returns the envelope's `llm' map
%% unchanged -- the mock directive opts the actor passes to soma_llm_call today.
test_empty_or_directive_model_config_returns_mock_opts_unchanged() ->
    Llm = #{directive => proposal,
            proposal => #{kind => reply, body => <<"hi">>}},
    Envelope = #{llm => Llm, payload => #{prompt => <<"hello">>}},
    ?assertEqual(Llm, soma_actor:build_call_opts(#{}, Envelope)),
    ?assertEqual(Llm, soma_actor:build_call_opts(#{directive => proposal},
                                                 Envelope)).

empty_or_directive_model_config_returns_mock_opts_unchanged_test() ->
    test_empty_or_directive_model_config_returns_mock_opts_unchanged().

%% The payload key `soma_cli_server:ask_envelope/4' writes the intent under must
%% be the same key `soma_actor:build_call_opts/2' reads the prompt from. Feeding
%% the handler's own ask envelope through the real-provider builder pins the two
%% sides together: the intent text must reach the user message, not the empty
%% default -- so a one-sided rename of either key is caught.
test_handle_ask_payload_key_matches_build_call_opts_reader() ->
    Intent = <<"summarize the design">>,
    Envelope = soma_cli_server:ask_envelope(Intent,
                                            <<"task-1">>,
                                            <<"corr-1">>,
                                            #{}),
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    ?assertEqual([#{role => <<"user">>, content => Intent}],
                 maps:get(messages, Opts)).

handle_ask_payload_key_matches_build_call_opts_reader_test() ->
    test_handle_ask_payload_key_matches_build_call_opts_reader().
