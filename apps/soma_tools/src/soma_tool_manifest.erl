-module(soma_tool_manifest).

-export([normalize/1]).

-spec normalize(map()) -> {ok, map()} | {error, term()}.
normalize(#{
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
normalize(#{
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
