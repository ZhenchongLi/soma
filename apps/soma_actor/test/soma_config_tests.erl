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
    try
        Config = soma_config:load(#{config_path => Path}),
        ?assertEqual(openai_compat, maps:get(provider, Config)),
        ?assertEqual(<<"api.example/v1">>, maps:get(base_url, Config)),
        ?assertEqual(<<"deepseek-v4">>, maps:get(model, Config))
    after
        file:delete(Path)
    end.

load_llm_table_builds_provider_map_test() ->
    test_load_llm_table_builds_provider_map().

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
