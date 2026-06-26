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
