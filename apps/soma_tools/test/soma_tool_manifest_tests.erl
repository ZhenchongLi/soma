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

%% A manifest may optionally carry the model-facing half: a binary description
%% and a params list of #{name (binary), type (string|integer|boolean),
%% required (boolean)} specs, each optionally with a binary doc. normalize/1
%% must accept both and preserve them in the normalized descriptor.
test_normalize_accepts_description_and_params() ->
    Description = <<"Read a file from the sandboxed root.">>,
    Params = [
        #{
            name => <<"path">>,
            type => string,
            required => true,
            doc => <<"Path relative to the sandbox root.">>
        },
        #{name => <<"max_bytes">>, type => integer, required => false},
        #{name => <<"binary_mode">>, type => boolean, required => false}
    ],
    Manifest = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read,
        description => Description,
        params => Params
    },
    {ok, Normalized} = soma_tool_manifest:normalize(Manifest),
    ?assertEqual(Description, maps:get(description, Normalized, missing)),
    ?assertEqual(Params, maps:get(params, Normalized, missing)).

normalize_accepts_description_and_params_test() ->
    test_normalize_accepts_description_and_params().

%% Invalid model-facing fields fail closed with named errors. A non-binary
%% description is {error, {invalid_description, _}}; any malformed params value
%% — a non-list params, a non-map spec, a spec missing name/type/required, a
%% type outside string|integer|boolean, or a non-binary doc — is
%% {error, {invalid_params, _}} carrying the offending value.
test_normalize_rejects_invalid_model_facing_fields() ->
    Base = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    GoodSpec = #{name => <<"path">>, type => string, required => true},
    %% Non-binary description → {error, {invalid_description, Value}}.
    lists:foreach(
        fun(Value) ->
            ?assertEqual(
                {error, {invalid_description, Value}},
                soma_tool_manifest:normalize(Base#{description => Value})
            )
        end,
        ["read a file", read_a_file, 42]
    ),
    %% Non-list params → {error, {invalid_params, Params}}.
    lists:foreach(
        fun(Value) ->
            ?assertEqual(
                {error, {invalid_params, Value}},
                soma_tool_manifest:normalize(Base#{params => Value})
            )
        end,
        [not_a_list, #{}, <<"path">>]
    ),
    %% A malformed spec inside the list → {error, {invalid_params, Spec}}
    %% carrying the offending spec.
    BadSpecs = [
        %% Not a map.
        not_a_map,
        %% Missing name / type / required.
        maps:remove(name, GoodSpec),
        maps:remove(type, GoodSpec),
        maps:remove(required, GoodSpec),
        %% type outside string | integer | boolean.
        GoodSpec#{type => float},
        %% Non-binary doc.
        GoodSpec#{doc => "path to read"}
    ],
    lists:foreach(
        fun(BadSpec) ->
            ?assertEqual(
                {error, {invalid_params, BadSpec}},
                soma_tool_manifest:normalize(Base#{params => [GoodSpec, BadSpec]})
            )
        end,
        BadSpecs
    ),
    %% An improper list ([GoodSpec | garbage]) passes is_list/1's head
    %% cons-cell check; it must reject, not crash the caller.
    ?assertEqual(
        {error, {invalid_params, garbage}},
        soma_tool_manifest:normalize(Base#{params => [GoodSpec | garbage]})
    ).

normalize_rejects_invalid_model_facing_fields_test() ->
    test_normalize_rejects_invalid_model_facing_fields().

%% A v1 manifest — one without description/params — must normalize to exactly
%% the descriptor it produced before the model-facing half existed: no new keys
%% appear, for either adapter. Exact-map equality pins the full shape;
%% the explicit is_key checks name the two keys that must stay absent.
test_normalize_without_model_facing_fields_adds_no_keys() ->
    ErlangManifest = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    CliManifest = #{
        name => echo,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => cli,
        executable => "echo",
        argv => ["hi"]
    },
    lists:foreach(
        fun(Manifest) ->
            ?assertEqual(
                {ok, Manifest},
                soma_tool_manifest:normalize(Manifest)
            ),
            {ok, Normalized} = soma_tool_manifest:normalize(Manifest),
            ?assertNot(maps:is_key(description, Normalized)),
            ?assertNot(maps:is_key(params, Normalized))
        end,
        [ErlangManifest, CliManifest]
    ).

normalize_without_model_facing_fields_adds_no_keys_test() ->
    test_normalize_without_model_facing_fields_adds_no_keys().

%% Every rejection's error reason must name the field it blames: the reason is a
%% {Tag, ...} tuple whose tag (or payload, for missing_field) carries the
%% offending field name. One malformed manifest per blamed field.
test_reject_reason_names_field() ->
    ErlangBase = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read
    },
    CliBase = #{
        name => echo,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => cli,
        executable => "echo",
        argv => ["hi"]
    },
    Cases = [
        {maps:remove(name, ErlangBase), name},
        {ErlangBase#{effect => destroyer}, effect},
        {ErlangBase#{idempotent => yes}, idempotent},
        {ErlangBase#{timeout_ms => 0}, timeout_ms},
        {ErlangBase#{adapter => grpc}, adapter},
        {maps:remove(module, ErlangBase), module},
        {CliBase#{executable => "echo hi"}, executable},
        {CliBase#{argv => not_a_list}, argv}
    ],
    lists:foreach(
        fun({Manifest, Field}) ->
            {error, Reason} = soma_tool_manifest:normalize(Manifest),
            ?assert(reason_names_field(Reason, Field))
        end,
        Cases
    ).

%% A reason names a field when the field atom appears anywhere in the reason
%% tuple — either as the payload (missing_field) or encoded in the tag
%% (invalid_<field>).
reason_names_field(Reason, Field) ->
    lists:member(Field, reason_field_names(Reason)).

reason_field_names({missing_field, Field}) ->
    [Field];
reason_field_names({Tag, _Value}) ->
    case atom_to_list(Tag) of
        "invalid_" ++ FieldStr -> [list_to_atom(FieldStr)];
        _ -> []
    end.

reject_reason_names_field_test() ->
    test_reject_reason_names_field().

%% Re-normalizing an already-normalized manifest returns an equal map, so a
%% valid manifest has one canonical internal shape. For each adapter, normalize
%% once to get M2, then assert normalize(M2) == {ok, M2}.
test_normalize_is_idempotent() ->
    ErlangManifest = #{
        name => file_read,
        effect => reader,
        idempotent => true,
        timeout_ms => 1000,
        adapter => erlang_module,
        module => soma_tool_file_read,
        %% A stray key that normalize must drop, so the first pass actually
        %% reshapes the map rather than returning it unchanged.
        stray => leftover
    },
    CliManifest = #{
        name => echo,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => cli,
        executable => "echo",
        argv => ["hi"],
        stray => leftover
    },
    lists:foreach(
        fun(Manifest) ->
            {ok, M2} = soma_tool_manifest:normalize(Manifest),
            ?assertEqual({ok, M2}, soma_tool_manifest:normalize(M2))
        end,
        [ErlangManifest, CliManifest]
    ).

normalize_is_idempotent_test() ->
    test_normalize_is_idempotent().

%% A cli manifest is malformed unless it carries both executable and argv.
%% Dropping either must be rejected with {error, {missing_field, _}}, not crash
%% with function_clause.
test_normalize_rejects_cli_without_executable_or_argv() ->
    Base = #{
        name => echo,
        effect => identity,
        idempotent => true,
        timeout_ms => 1000,
        adapter => cli,
        executable => "echo",
        argv => ["hi"]
    },
    ?assertEqual(
        {error, {missing_field, argv}},
        soma_tool_manifest:normalize(maps:remove(argv, Base))
    ),
    ?assertEqual(
        {error, {missing_field, executable}},
        soma_tool_manifest:normalize(maps:remove(executable, Base))
    ),
    ?assertEqual(
        {error, {missing_field, executable}},
        soma_tool_manifest:normalize(maps:without([executable, argv], Base))
    ).

normalize_rejects_cli_without_executable_or_argv_test() ->
    test_normalize_rejects_cli_without_executable_or_argv().

%% Each of the five built-in tools exposes a production manifest/0 whose output
%% normalizes to {ok, _}. The manifest is read live from the module, not a
%% hand-written fixture.
test_builtin_manifests_normalize() ->
    Modules = [
        soma_tool_echo,
        soma_tool_sleep,
        soma_tool_fail,
        soma_tool_file_read,
        soma_tool_file_write
    ],
    lists:foreach(
        fun(Module) ->
            ?assertMatch(
                {ok, _},
                soma_tool_manifest:normalize(Module:manifest())
            )
        end,
        Modules
    ).

builtin_manifests_normalize_test() ->
    test_builtin_manifests_normalize().

%% Each built-in's normalized manifest carries the same name, effect,
%% idempotent, and timeout_ms that the tool's describe/0 returns, so the
%% manifest's metadata cannot drift from describe/0's.
test_builtin_manifest_metadata_matches_describe() ->
    Modules = [
        soma_tool_echo,
        soma_tool_sleep,
        soma_tool_fail,
        soma_tool_file_read,
        soma_tool_file_write
    ],
    MetaKeys = [name, effect, idempotent, timeout_ms],
    lists:foreach(
        fun(Module) ->
            {ok, Manifest} = soma_tool_manifest:normalize(Module:manifest()),
            Describe = Module:describe(),
            ?assertEqual(
                maps:with(MetaKeys, Describe),
                maps:with(MetaKeys, Manifest)
            )
        end,
        Modules
    ).

builtin_manifest_metadata_matches_describe_test() ->
    test_builtin_manifest_metadata_matches_describe().

%% Each built-in's normalized manifest names erlang_module as its adapter and
%% points module at the backing tool module, so a built-in resolves to the
%% Erlang module that implements it.
test_builtin_manifest_names_erlang_module_adapter() ->
    Pairs = [
        {soma_tool_echo, soma_tool_echo},
        {soma_tool_sleep, soma_tool_sleep},
        {soma_tool_fail, soma_tool_fail},
        {soma_tool_file_read, soma_tool_file_read},
        {soma_tool_file_write, soma_tool_file_write}
    ],
    lists:foreach(
        fun({Module, BackingModule}) ->
            {ok, Manifest} = soma_tool_manifest:normalize(Module:manifest()),
            ?assertEqual(erlang_module, maps:get(adapter, Manifest)),
            ?assertEqual(BackingModule, maps:get(module, Manifest))
        end,
        Pairs
    ).

builtin_manifest_names_erlang_module_adapter_test() ->
    test_builtin_manifest_names_erlang_module_adapter().
