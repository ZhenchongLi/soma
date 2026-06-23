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
