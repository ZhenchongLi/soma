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

%% Criterion #10: with `XDG_RUNTIME_DIR' unset, the shared resolver returns a
%% stable per-user `/tmp/soma-<user>.sock', and the path is identical when
%% computed in this process and in a separate OS process for the same user.
test_resolver_per_user_path_stable_across_processes() ->
    Saved = os:getenv("XDG_RUNTIME_DIR"),
    try
        true = os:unsetenv("XDG_RUNTIME_DIR"),
        Here = soma_cli:resolve_socket(#{}),
        %% Shape: /tmp/soma-<user>.sock, with a non-empty <user> segment.
        ?assertEqual(match,
                     re:run(Here, "^/tmp/soma-.+\\.sock$", [{capture, none}])),
        %% Second OS process: a fresh `erl' computes the same path off the same
        %% user identity. Hermetic -- no network, just the loaded code path.
        Ebins = code:get_path(),
        PathArgs = lists:append([["-pa", E] || E <- Ebins]),
        Eval = "io:format(\"~s\", [soma_cli:resolve_socket(\#{})]), halt(0).",
        Other0 = os:cmd(string:join(
            ["erl -noshell"] ++ PathArgs ++ ["-eval", "'" ++ Eval ++ "'"], " ")),
        Other = string:trim(Other0),
        ?assertEqual(Here, Other)
    after
        restore_env("XDG_RUNTIME_DIR", Saved)
    end.

resolver_per_user_path_stable_across_processes_test() ->
    test_resolver_per_user_path_stable_across_processes().

restore_env(Var, false) ->
    os:unsetenv(Var);
restore_env(Var, Value) ->
    os:putenv(Var, Value).
