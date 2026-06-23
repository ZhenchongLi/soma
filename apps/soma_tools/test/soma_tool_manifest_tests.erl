-module(soma_tool_manifest_tests).

-include_lib("eunit/include/eunit.hrl").

test_normalize_accepts_erlang_module() ->
    Manifest = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    ?assertEqual({ok, Manifest}, soma_tool_manifest:normalize(Manifest)).

normalize_accepts_erlang_module_test() ->
    test_normalize_accepts_erlang_module().

test_normalize_accepts_cli() ->
    Manifest = #{
        name => echo,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => cli,
        executable => "echo",
        argv => ["hi"]
    },
    ?assertEqual({ok, Manifest}, soma_tool_manifest:normalize(Manifest)).

normalize_accepts_cli_test() ->
    test_normalize_accepts_cli().

test_normalize_rejects_missing_shared_field() ->
    Base = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    lists:foreach(
        fun(Key) ->
            Manifest = maps:remove(Key, Base),
            ?assertEqual(
                {error, {missing_field, Key}},
                soma_tool_manifest:normalize(Manifest)
            )
        end,
        [name, effect, idempotent, timeout_ms, adapter]
    ).

normalize_rejects_missing_shared_field_test() ->
    test_normalize_rejects_missing_shared_field().

test_normalize_rejects_bad_effect() ->
    Manifest = #{
        name => file_read,
        effect => destroyer,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    ?assertEqual(
        {error, {invalid_effect, destroyer}},
        soma_tool_manifest:normalize(Manifest)
    ).

normalize_rejects_bad_effect_test() ->
    test_normalize_rejects_bad_effect().

test_normalize_rejects_non_boolean_idempotent() ->
    Manifest = #{
        name => file_read,
        effect => reader,
        idempotent => yes,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    ?assertEqual(
        {error, {invalid_idempotent, yes}},
        soma_tool_manifest:normalize(Manifest)
    ).

normalize_rejects_non_boolean_idempotent_test() ->
    test_normalize_rejects_non_boolean_idempotent().

test_normalize_rejects_bad_timeout_ms() ->
    Base = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    lists:foreach(
        fun(Value) ->
            Manifest = Base#{timeout_ms => Value},
            ?assertEqual(
                {error, {invalid_timeout_ms, Value}},
                soma_tool_manifest:normalize(Manifest)
            )
        end,
        [0, -1, "1000"]
    ).

normalize_rejects_bad_timeout_ms_test() ->
    test_normalize_rejects_bad_timeout_ms().

test_normalize_rejects_unknown_adapter() ->
    Manifest = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => grpc,
        module => soma_tool_file_read
    },
    ?assertEqual(
        {error, {invalid_adapter, grpc}},
        soma_tool_manifest:normalize(Manifest)
    ).

normalize_rejects_unknown_adapter_test() ->
    test_normalize_rejects_unknown_adapter().

test_normalize_rejects_erlang_module_without_module() ->
    Manifest = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module
    },
    ?assertEqual(
        {error, {missing_field, module}},
        soma_tool_manifest:normalize(Manifest)
    ).

normalize_rejects_erlang_module_without_module_test() ->
    test_normalize_rejects_erlang_module_without_module().

test_normalize_rejects_shell_string_executable() ->
    Base = #{
        name => echo,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => cli,
        argv => ["hi"]
    },
    %% A single-token executable still passes (string or binary).
    ?assertMatch(
        {ok, _},
        soma_tool_manifest:normalize(Base#{executable => "echo"})
    ),
    ?assertMatch(
        {ok, _},
        soma_tool_manifest:normalize(Base#{executable => "/bin/echo"})
    ),
    ?assertMatch(
        {ok, _},
        soma_tool_manifest:normalize(Base#{executable => <<"/bin/echo">>})
    ),
    %% An executable carrying internal whitespace is rejected.
    lists:foreach(
        fun(Value) ->
            ?assertEqual(
                {error, {invalid_executable, Value}},
                soma_tool_manifest:normalize(Base#{executable => Value})
            )
        end,
        ["echo hi", "/bin/sh -c 'echo hi'", "echo\thi", <<"echo hi">>]
    ).

normalize_rejects_shell_string_executable_test() ->
    test_normalize_rejects_shell_string_executable().

test_normalize_rejects_non_list_argv() ->
    Base = #{
        name => echo,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => cli,
        executable => "echo"
    },
    lists:foreach(
        fun(Value) ->
            ?assertEqual(
                {error, {invalid_argv, Value}},
                soma_tool_manifest:normalize(Base#{argv => Value})
            )
        end,
        [not_a_list, <<"hi">>, #{}, 42]
    ).

normalize_rejects_non_list_argv_test() ->
    test_normalize_rejects_non_list_argv().
