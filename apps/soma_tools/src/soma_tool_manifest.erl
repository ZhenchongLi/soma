-module(soma_tool_manifest).

-export([normalize/1]).

-define(SHARED_FIELDS, [name, effect, idempotent, timeout_ms, adapter]).
-define(EFFECTS, [identity, reader, state]).
-define(ADAPTERS, [erlang_module, cli]).

-spec normalize(map()) -> {ok, map()} | {error, term()}.
normalize(Manifest) when is_map(Manifest) ->
    case missing_shared_field(Manifest) of
        {missing, Key} -> {error, {missing_field, Key}};
        none -> check_effect(Manifest)
    end.

missing_shared_field(Manifest) ->
    case [K || K <- ?SHARED_FIELDS, not maps:is_key(K, Manifest)] of
        [Key | _] -> {missing, Key};
        [] -> none
    end.

check_effect(#{effect := Effect} = Manifest) ->
    case lists:member(Effect, ?EFFECTS) of
        true -> check_idempotent(Manifest);
        false -> {error, {invalid_effect, Effect}}
    end.

check_idempotent(#{idempotent := Idempotent} = Manifest) ->
    case is_boolean(Idempotent) of
        true -> check_timeout_ms(Manifest);
        false -> {error, {invalid_idempotent, Idempotent}}
    end.

check_timeout_ms(#{timeout_ms := TimeoutMs} = Manifest) ->
    case is_integer(TimeoutMs) andalso TimeoutMs > 0 of
        true -> check_adapter(Manifest);
        false -> {error, {invalid_timeout_ms, TimeoutMs}}
    end.

check_adapter(#{adapter := Adapter} = Manifest) ->
    case lists:member(Adapter, ?ADAPTERS) of
        true -> normalize_complete(Manifest);
        false -> {error, {invalid_adapter, Adapter}}
    end.

normalize_complete(#{
    name := Name,
    effect := Effect,
    idempotent := Idempotent,
    timeout_ms := TimeoutMs,
    adapter := erlang_module,
    module := Module
}) ->
    Manifest = #{
        name => Name,
        effect => Effect,
        idempotent => Idempotent,
        timeout_ms => TimeoutMs,
        adapter => erlang_module,
        module => Module
    },
    {ok, Manifest};
normalize_complete(#{
    name := Name,
    effect := Effect,
    idempotent := Idempotent,
    timeout_ms := TimeoutMs,
    adapter := cli,
    executable := Executable,
    argv := Argv
}) ->
    Manifest = #{
        name => Name,
        effect => Effect,
        idempotent => Idempotent,
        timeout_ms => TimeoutMs,
        adapter => cli,
        executable => Executable,
        argv => Argv
    },
    {ok, Manifest}.
