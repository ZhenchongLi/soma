-module(soma_config_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1: load/1 reads a minimal TOML file with an [llm] table and returns
%% #{provider => openai_compat, base_url => <<_>>, model => <<_>>}, mapping the
%% provider value to the atom openai_compat and base_url/model to binaries.
test_load_llm_table_builds_provider_map() ->
    Toml =
        "# a comment\n"
        "\n"
        "[llm]\n"
        "provider = \"openai_compat\"\n"
        "base_url = \"api.example/v1\"\n"
        "model = \"deepseek-v4\"\n",
    Path = write_temp_config(Toml),
    Prev = os:getenv("SOMA_LLM_API_KEY"),
    os:putenv("SOMA_LLM_API_KEY", "sk-test-sentinel-137"),
    try
        Config = soma_config:load(#{config_path => Path}),
        ?assertEqual(openai_compat, maps:get(provider, Config)),
        ?assertEqual(<<"api.example/v1">>, maps:get(base_url, Config)),
        ?assertEqual(<<"deepseek-v4">>, maps:get(model, Config))
    after
        case Prev of
            false -> os:unsetenv("SOMA_LLM_API_KEY");
            _ -> os:putenv("SOMA_LLM_API_KEY", Prev)
        end,
        file:delete(Path)
    end.

load_llm_table_builds_provider_map_test() ->
    test_load_llm_table_builds_provider_map().

%% Criterion 2: optional keys enable_thinking (bool) and max_tokens (int) are
%% carried into the built map under the same key when the file sets them; a key
%% absent from the file is left off the map.
test_load_carries_optional_keys_and_omits_absent() ->
    WithBoth =
        "[llm]\n"
        "provider = \"openai_compat\"\n"
        "base_url = \"api.example/v1\"\n"
        "model = \"deepseek-v4\"\n"
        "enable_thinking = true\n"
        "max_tokens = 2048\n",
    Without =
        "[llm]\n"
        "provider = \"openai_compat\"\n"
        "base_url = \"api.example/v1\"\n"
        "model = \"deepseek-v4\"\n",
    PathBoth = write_temp_config(WithBoth),
    PathWithout = write_temp_config(Without),
    Prev = os:getenv("SOMA_LLM_API_KEY"),
    os:putenv("SOMA_LLM_API_KEY", "sk-test-sentinel-137"),
    try
        ConfigBoth = soma_config:load(#{config_path => PathBoth}),
        ?assertEqual(true, maps:get(enable_thinking, ConfigBoth)),
        ?assertEqual(2048, maps:get(max_tokens, ConfigBoth)),
        ConfigWithout = soma_config:load(#{config_path => PathWithout}),
        ?assertEqual(false, maps:is_key(enable_thinking, ConfigWithout)),
        ?assertEqual(false, maps:is_key(max_tokens, ConfigWithout))
    after
        case Prev of
            false -> os:unsetenv("SOMA_LLM_API_KEY");
            _ -> os:putenv("SOMA_LLM_API_KEY", Prev)
        end,
        file:delete(PathBoth),
        file:delete(PathWithout)
    end.

load_carries_optional_keys_and_omits_absent_test() ->
    test_load_carries_optional_keys_and_omits_absent().

%% Criterion 3: load/1 reads SOMA_LLM_API_KEY and puts its value into the built
%% map as api_key => <<value>>.
test_load_reads_api_key_from_env() ->
    Toml =
        "[llm]\n"
        "provider = \"openai_compat\"\n"
        "base_url = \"api.example/v1\"\n"
        "model = \"deepseek-v4\"\n",
    Path = write_temp_config(Toml),
    Prev = os:getenv("SOMA_LLM_API_KEY"),
    os:putenv("SOMA_LLM_API_KEY", "sk-test-sentinel-137"),
    try
        Config = soma_config:load(#{config_path => Path}),
        ?assertEqual(<<"sk-test-sentinel-137">>, maps:get(api_key, Config))
    after
        case Prev of
            false -> os:unsetenv("SOMA_LLM_API_KEY");
            _ -> os:putenv("SOMA_LLM_API_KEY", Prev)
        end,
        file:delete(Path)
    end.

load_reads_api_key_from_env_test() ->
    test_load_reads_api_key_from_env().

%% Criterion 4: an api_key line in the config file is never forwarded — the
%% built map's api_key comes only from SOMA_LLM_API_KEY, and the file's value
%% appears nowhere in the map.
test_load_drops_api_key_from_file() ->
    FileSentinel = "sk-from-file-DO-NOT-FORWARD",
    EnvValue = "sk-from-env-137",
    Toml =
        "[llm]\n"
        "provider = \"openai_compat\"\n"
        "base_url = \"api.example/v1\"\n"
        "model = \"deepseek-v4\"\n"
        "api_key = \"" ++ FileSentinel ++ "\"\n",
    Path = write_temp_config(Toml),
    Prev = os:getenv("SOMA_LLM_API_KEY"),
    os:putenv("SOMA_LLM_API_KEY", EnvValue),
    try
        Config = soma_config:load(#{config_path => Path}),
        ?assertEqual(list_to_binary(EnvValue), maps:get(api_key, Config)),
        Rendered = lists:flatten(io_lib:format("~p", [Config])),
        ?assertEqual(nomatch, string:find(Rendered, FileSentinel))
    after
        case Prev of
            false -> os:unsetenv("SOMA_LLM_API_KEY");
            _ -> os:putenv("SOMA_LLM_API_KEY", Prev)
        end,
        file:delete(Path)
    end.

load_drops_api_key_from_file_test() ->
    test_load_drops_api_key_from_file().

%% Criterion 5: when the config selects a provider and SOMA_LLM_API_KEY is unset
%% or empty, load/1 fails loudly with a named error ({missing_env, _}) and never
%% returns a map carrying an empty api_key.
test_load_no_api_key_raises() ->
    Toml =
        "[llm]\n"
        "provider = \"openai_compat\"\n"
        "base_url = \"api.example/v1\"\n"
        "model = \"deepseek-v4\"\n",
    Path = write_temp_config(Toml),
    Prev = os:getenv("SOMA_LLM_API_KEY"),
    try
        os:unsetenv("SOMA_LLM_API_KEY"),
        ?assertError({missing_env, _},
                     soma_config:load(#{config_path => Path})),
        os:putenv("SOMA_LLM_API_KEY", ""),
        ?assertError({missing_env, _},
                     soma_config:load(#{config_path => Path}))
    after
        case Prev of
            false -> os:unsetenv("SOMA_LLM_API_KEY");
            _ -> os:putenv("SOMA_LLM_API_KEY", Prev)
        end,
        file:delete(Path)
    end.

load_no_api_key_raises_test() ->
    test_load_no_api_key_raises().

%% Criterion 6: an absent config file, or a file with no [llm] table, makes
%% load/1 return undefined.
test_load_absent_or_no_llm_table_is_undefined() ->
    Dir = case os:getenv("TMPDIR") of
              false -> "/tmp";
              "" -> "/tmp";
              D -> D
          end,
    AbsentName = lists:flatten(
                   io_lib:format("soma_config_absent_~p_~p.toml",
                                 [os:getpid(),
                                  erlang:unique_integer([positive])])),
    AbsentPath = filename:join(Dir, AbsentName),
    NoTableToml =
        "# just a comment\n"
        "\n"
        "# no llm table here\n",
    NoTablePath = write_temp_config(NoTableToml),
    try
        ?assertEqual(undefined,
                     soma_config:load(#{config_path => AbsentPath})),
        ?assertEqual(undefined,
                     soma_config:load(#{config_path => NoTablePath}))
    after
        file:delete(NoTablePath)
    end.

load_absent_or_no_llm_table_is_undefined_test() ->
    test_load_absent_or_no_llm_table_is_undefined().

write_temp_config(Contents) ->
    Dir = case os:getenv("TMPDIR") of
              false -> "/tmp";
              "" -> "/tmp";
              D -> D
          end,
    Name = lists:flatten(
             io_lib:format("soma_config_~p_~p.toml",
                           [os:getpid(), erlang:unique_integer([positive])])),
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Contents),
    Path.
