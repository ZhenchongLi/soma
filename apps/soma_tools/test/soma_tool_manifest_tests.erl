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
