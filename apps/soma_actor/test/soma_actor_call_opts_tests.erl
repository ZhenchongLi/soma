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

%% The planning branch now reads soma_tool_registry:catalog/0 on every build
%% (#212), so this test runs under the same registry fixture the registry's own
%% eunit tests use.
planning_mode_builds_run_steps_system_message_over_allowed_tools_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(
            test_planning_mode_builds_run_steps_system_message_over_allowed_tools())
     end}.

%% Criterion 1 (#212): with a concrete allowlist, the planning system prompt
%% consumes the tool catalog. Each allowed tool that has a catalog entry gets a
%% Lisp `(tool ...)' block carrying its registry-spelled name, description, and
%% declared params; a catalog entry outside the allowlist (file_write, seeded by
%% the registry) leaves no trace; an allowed tool without a catalog entry (a v1
%% manifest with no description) still appears in the plain tool-name list; and
%% the `(run-steps ...)' answer directive is kept. Needs the live registry --
%% the builder reads soma_tool_registry:catalog/0 on every planning build.
test_planning_prompt_renders_allowed_catalog_entries() ->
    Described = #{
        name => described_plan_tool,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo,
        description => <<"Reverses the given input for planning.">>,
        params => [#{name => <<"reversal_input">>,
                     type => string,
                     required => true,
                     doc => <<"What to reverse.">>}]
    },
    Bare = #{
        name => bare_plan_tool,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo
    },
    ok = soma_tool_registry:register_tool(Described),
    ok = soma_tool_registry:register_tool(Bare),
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    plan => true,
                    allowed_tools => [echo, described_plan_tool,
                                      bare_plan_tool]},
    Envelope = #{payload => #{prompt => <<"reverse the file name">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    [System | _] = maps:get(messages, Opts),
    ?assertEqual(<<"system">>, maps:get(role, System)),
    Content = maps:get(content, System),
    ?assert(is_binary(Content)),
    %% The (run-steps ...) answer directive is kept.
    ?assertNotEqual(nomatch, binary:match(Content, <<"(run-steps">>)),
    %% Allowed tools with catalog entries render as (tool ...) blocks carrying
    %% name (registry spelling, underscores), description, and declared params.
    ?assertNotEqual(nomatch, binary:match(Content, <<"(tool">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Content, <<"described_plan_tool">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Content,
                                 <<"Reverses the given input for planning.">>)),
    ?assertNotEqual(nomatch, binary:match(Content, <<"reversal_input">>)),
    %% echo is an allowed built-in with a catalog entry: its description shows.
    ?assertNotEqual(nomatch,
                    binary:match(Content, <<"Returns its input unchanged.">>)),
    %% file_write has a catalog entry but is off the allowlist: no trace.
    ?assertEqual(nomatch, binary:match(Content, <<"file_write">>)),
    %% An allowed tool without a catalog entry still shows in the plain list.
    ?assertNotEqual(nomatch, binary:match(Content, <<"bare_plan_tool">>)).

planning_prompt_renders_allowed_catalog_entries_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_planning_prompt_renders_allowed_catalog_entries())
     end}.

%% Criterion 2 (#212): with an `all' policy (`allowed_tools => all', the
%% tool_policy default `planning_tools/2' threads through), the planning system
%% prompt renders every catalog entry -- each seeded built-in's registry-spelled
%% name and description appear -- and keeps the `(run-steps ...)' answer
%% directive. `all' names no concrete tools, so the whole catalog *is* the
%% offer; today's prompt drops the catalog entirely on that branch.
test_planning_prompt_all_policy_renders_full_catalog() ->
    Catalog = soma_tool_registry:catalog(),
    CatalogNames = lists:sort([Name || #{name := Name} <- Catalog]),
    %% The registry seeds the seven described built-ins -- the loop below is
    %% not vacuous.
    ?assertEqual([echo, fail, file_read, file_write, sleep, text_grep,
                  text_head],
                 CatalogNames),
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    plan => true,
                    allowed_tools => all},
    Envelope = #{payload => #{prompt => <<"do something useful">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    [System | _] = maps:get(messages, Opts),
    ?assertEqual(<<"system">>, maps:get(role, System)),
    Content = maps:get(content, System),
    ?assert(is_binary(Content)),
    %% The (run-steps ...) answer directive is kept.
    ?assertNotEqual(nomatch, binary:match(Content, <<"(run-steps">>)),
    %% Every catalog entry's name (registry spelling, underscores) and
    %% description appear in the prompt.
    lists:foreach(
      fun(#{name := Name, description := Description}) ->
              ?assertNotEqual(nomatch,
                              binary:match(Content,
                                           atom_to_binary(Name, utf8))),
              ?assertNotEqual(nomatch, binary:match(Content, Description))
      end,
      Catalog).

planning_prompt_all_policy_renders_full_catalog_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_planning_prompt_all_policy_renders_full_catalog())
     end}.

%% Criterion 3 (#212): a tool registered through register_tool/1 with a
%% description appears in the *next* planning prompt built after registration
%% -- no code change, no actor restart. The builder must read
%% soma_tool_registry:catalog/0 fresh on every planning build, never cache it:
%% the same model_config builds a prompt without the tool before registration
%% and a prompt carrying its name and description right after.
test_registered_tool_appears_in_next_planning_prompt() ->
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    plan => true,
                    allowed_tools => all},
    Envelope = #{payload => #{prompt => <<"use the newest tool">>}},
    OptsBefore = soma_actor:build_call_opts(ModelConfig, Envelope),
    [SystemBefore | _] = maps:get(messages, OptsBefore),
    ContentBefore = maps:get(content, SystemBefore),
    %% Before registration the tool leaves no trace in the prompt.
    ?assertEqual(nomatch,
                 binary:match(ContentBefore, <<"late_registered_tool">>)),
    ?assertEqual(nomatch,
                 binary:match(ContentBefore,
                              <<"Registered after the first prompt build.">>)),
    Manifest = #{
        name => late_registered_tool,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_echo,
        description => <<"Registered after the first prompt build.">>
    },
    ok = soma_tool_registry:register_tool(Manifest),
    %% Same config, next build: the fresh catalog read carries the new tool.
    OptsAfter = soma_actor:build_call_opts(ModelConfig, Envelope),
    [SystemAfter | _] = maps:get(messages, OptsAfter),
    ContentAfter = maps:get(content, SystemAfter),
    ?assertNotEqual(nomatch,
                    binary:match(ContentAfter, <<"late_registered_tool">>)),
    ?assertNotEqual(nomatch,
                    binary:match(ContentAfter,
                                 <<"Registered after the first prompt build.">>)).

registered_tool_appears_in_next_planning_prompt_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_registered_tool_appears_in_next_planning_prompt())
     end}.

%% Criterion 4 (#212), no-leak half: the planning prompt is built from
%% soma_tool_registry:catalog/0 entries only -- never from raw descriptors --
%% so none of the runtime-internal descriptor fields can appear. Register a
%% described `cli' tool whose descriptor carries distinctive `executable' /
%% `argv' values; the built prompt renders its name and description (proving
%% the entry is in play) while carrying no trace of the executable path, the
%% argv value, a built-in's module name, or the `effect' / `idempotent' /
%% `timeout_ms' field text.
test_planning_prompt_carries_no_runtime_descriptor_fields() ->
    Manifest = #{
        name => cli_leak_probe_tool,
        effect => state,
        idempotent => false,
        timeout_ms => 4321,
        adapter => cli,
        executable => <<"/opt/leak-probe/bin/upperize_secret">>,
        argv => [<<"--leak-probe-flag">>],
        description => <<"Uppercases input via an external helper.">>
    },
    ok = soma_tool_registry:register_tool(Manifest),
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    plan => true,
                    allowed_tools => [echo, cli_leak_probe_tool]},
    Envelope = #{payload => #{prompt => <<"uppercase the file name">>}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    [System | _] = maps:get(messages, Opts),
    ?assertEqual(<<"system">>, maps:get(role, System)),
    Content = maps:get(content, System),
    ?assert(is_binary(Content)),
    %% The tool's catalog entry is in play: name and description render.
    ?assertNotEqual(nomatch, binary:match(Content, <<"cli_leak_probe_tool">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Content,
                                 <<"Uppercases input via an external helper.">>)),
    %% Runtime descriptor fields leave no trace: not the cli tool's executable
    %% path or argv value, not a built-in's module name, not the effect /
    %% idempotent / timeout_ms field text.
    ?assertEqual(nomatch,
                 binary:match(Content,
                              <<"/opt/leak-probe/bin/upperize_secret">>)),
    ?assertEqual(nomatch, binary:match(Content, <<"--leak-probe-flag">>)),
    ?assertEqual(nomatch, binary:match(Content, <<"soma_tool_echo">>)),
    ?assertEqual(nomatch, binary:match(Content, <<"effect">>)),
    ?assertEqual(nomatch, binary:match(Content, <<"idempotent">>)),
    ?assertEqual(nomatch, binary:match(Content, <<"timeout_ms">>)).

planning_prompt_carries_no_runtime_descriptor_fields_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(test_planning_prompt_carries_no_runtime_descriptor_fields())
     end}.

%% Criterion 6 (#219): a real-provider model_config carrying a binary
%% `system_prompt' places a first `system' message before the user prompt --
%% so a caller can steer the actor's non-planning conversation with a custom
%% system prompt, not just the planning-mode instruction.
test_real_provider_system_prompt_precedes_user_message() ->
    Prompt = <<"hello">>,
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    system_prompt => <<"custom">>},
    Envelope = #{payload => #{prompt => Prompt}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    ?assertEqual([#{role => <<"system">>, content => <<"custom">>},
                  #{role => <<"user">>, content => Prompt}],
                 maps:get(messages, Opts)).

real_provider_system_prompt_precedes_user_message_test() ->
    test_real_provider_system_prompt_precedes_user_message().

%% Criterion 7 (#219): a planning real-provider model_config (`plan => true')
%% that also carries a binary `system_prompt' orders the built messages as
%% custom system prompt, then the planning `(run-steps ...)' system message,
%% then the user prompt -- the caller's own instruction stays first, ahead of
%% the planning-mode instruction, with the user prompt last. Needs the tool
%% registry fixture: the planning branch reads soma_tool_registry:catalog/0.
test_planning_system_prompt_orders_custom_then_planning_then_user() ->
    Prompt = <<"summarize the file">>,
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    plan => true,
                    system_prompt => <<"custom">>,
                    allowed_tools => all},
    Envelope = #{payload => #{prompt => Prompt}},
    Opts = soma_actor:build_call_opts(ModelConfig, Envelope),
    Messages = maps:get(messages, Opts),
    [CustomSystem, PlanningSystem, User] = Messages,
    ?assertEqual(#{role => <<"system">>, content => <<"custom">>},
                 CustomSystem),
    ?assertEqual(<<"system">>, maps:get(role, PlanningSystem)),
    PlanningContent = maps:get(content, PlanningSystem),
    ?assert(is_binary(PlanningContent)),
    ?assertNotEqual(nomatch, binary:match(PlanningContent, <<"(run-steps">>)),
    ?assertEqual(#{role => <<"user">>, content => Prompt}, User).

planning_system_prompt_orders_custom_then_planning_then_user_test_() ->
    {setup,
     fun() -> {ok, Pid} = soma_tool_registry:start_link(), Pid end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         ?_test(
            test_planning_system_prompt_orders_custom_then_planning_then_user())
     end}.
