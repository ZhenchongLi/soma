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

%% `enable_thinking => true' in the model_config must thread through the builder
%% into the worker opts, and from there into the provider request body that
%% soma_llm_openai:build_request/1 shapes. The builder dropping the key is the
%% bug: feeding a real-provider config carrying enable_thinking and asserting both
%% that the opts carry it and that the decoded request body carries it pins the
%% whole pure path (no socket -- build_request/1 is pure) end to end.
test_enable_thinking_threads_through_to_request_body() ->
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    api_key => <<"sk-test">>,
                    enable_thinking => true},
    Envelope = #{payload => #{prompt => <<"hello">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    ?assertEqual(true, maps:get(enable_thinking, Opts)),
    #{body := Body} = soma_llm_openai:build_request(Opts),
    Decoded = json:decode(Body),
    ?assertEqual(true, maps:get(<<"enable_thinking">>, Decoded)).

enable_thinking_threads_through_to_request_body_test() ->
    test_enable_thinking_threads_through_to_request_body().

%% `max_tokens => N' in the model_config must thread through the builder into the
%% worker opts, and from there into the provider request body that
%% soma_llm_openai:build_request/1 shapes. The builder dropping the key is the
%% bug: feeding a real-provider config carrying max_tokens and asserting both
%% that the opts carry it and that the decoded request body carries it pins the
%% whole pure path (no socket -- build_request/1 is pure) end to end.
test_max_tokens_threads_through_to_request_body() ->
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    api_key => <<"sk-test">>,
                    max_tokens => 256},
    Envelope = #{payload => #{prompt => <<"hello">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    ?assertEqual(256, maps:get(max_tokens, Opts)),
    #{body := Body} = soma_llm_openai:build_request(Opts),
    Decoded = json:decode(Body),
    ?assertEqual(256, maps:get(<<"max_tokens">>, Decoded)).

max_tokens_threads_through_to_request_body_test() ->
    test_max_tokens_threads_through_to_request_body().

%% Criterion 2: in planning mode (`plan => true' on the model_config) the request
%% the actor builds carries a *system* message ahead of the user message,
%% instructing the model to emit a `(run-steps ...)' plan over the allowed tool
%% names. The allowed tools come from the actor's tool_policy, threaded into the
%% model_config the builder reads (`allowed_tools => [atom()]'). Feeding a planning
%% real-provider config with a concrete allowlist and asserting the first message
%% is a system message whose content mentions `(run-steps' and every allowed tool
%% name pins the planning instruction. The user message still follows.
test_planning_mode_builds_run_steps_system_message_over_allowed_tools() ->
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    plan => true,
                    allowed_tools => [echo, file_read]},
    Envelope = #{payload => #{prompt => <<"summarize the file">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    Messages = maps:get(messages, Opts),
    [System | Rest] = Messages,
    ?assertEqual(<<"system">>, maps:get(role, System)),
    SystemContent = maps:get(content, System),
    ?assert(is_binary(SystemContent)),
    ?assertNotEqual(nomatch, binary:match(SystemContent, <<"(run-steps">>)),
    ?assertNotEqual(nomatch, binary:match(SystemContent, <<"echo">>)),
    ?assertNotEqual(nomatch, binary:match(SystemContent, <<"file_read">>)),
    %% The user prompt message still follows the system message unchanged.
    ?assertEqual([#{role => <<"user">>, content => <<"summarize the file">>}],
                 Rest).

planning_mode_builds_run_steps_system_message_over_allowed_tools_test() ->
    test_planning_mode_builds_run_steps_system_message_over_allowed_tools().
