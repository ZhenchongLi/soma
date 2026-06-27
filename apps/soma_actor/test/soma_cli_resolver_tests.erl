%% @doc CLI.5 shared socket-path resolver proofs. Both `soma_cli:daemon/1' and
%% `soma_cli_main' resolve the listener path through one shared exported function;
%% these checks pin its behavior. No network: pure function calls.
-module(soma_cli_resolver_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion #9: the shared socket-path resolver returns
%% `$XDG_RUNTIME_DIR/soma.sock' when `XDG_RUNTIME_DIR' is set.
test_resolver_uses_xdg_runtime_dir() ->
    Saved = os:getenv("XDG_RUNTIME_DIR"),
    try
        Dir = "/tmp/soma-resolver-xdg-test",
        true = os:putenv("XDG_RUNTIME_DIR", Dir),
        Expected = filename:join(Dir, "soma.sock"),
        ?assertEqual(Expected, soma_cli:resolve_socket(#{}))
    after
        restore_env("XDG_RUNTIME_DIR", Saved)
    end.

resolver_uses_xdg_runtime_dir_test() ->
    test_resolver_uses_xdg_runtime_dir().

restore_env(Var, false) ->
    os:unsetenv(Var);
restore_env(Var, Value) ->
    os:putenv(Var, Value).
