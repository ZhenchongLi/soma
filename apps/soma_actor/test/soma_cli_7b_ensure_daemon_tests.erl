-module(soma_cli_7b_ensure_daemon_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #155 criterion 1 (CLI.7b): `soma_cli:ensure_daemon(#{socket => Path},
%% LaunchFun)' probes once with `soma_cli:ping/1'. When a `soma_cli_server' is
%% already listening on `Path' the probe returns `0', so `ensure_daemon' returns
%% `ok' and never touches `LaunchFun'. This test boots a real listener on a
%% unique-per-run socket path, passes a `LaunchFun' that records each call by
%% sending a message to the test process, and asserts both that `ensure_daemon'
%% returns `ok' and that the launcher was called zero times.
test_ensure_daemon_already_listening_skips_launch() ->
    Path = socket_path(),
    {ok, Server} = soma_cli_server:start_link(#{socket => Path}),
    Self = self(),
    LaunchFun = fun() -> Self ! launched, ok end,
    try
        %% Wait until the listener is actually accepting before probing.
        ok = wait_listening(Path, 80),
        ?assertEqual(ok, soma_cli:ensure_daemon(#{socket => Path}, LaunchFun)),
        ?assertEqual(0, count_launches())
    after
        unlink(Server),
        exit(Server, kill),
        _ = file:delete(Path)
    end.

ensure_daemon_already_listening_skips_launch_test_() ->
    {timeout, 30, fun test_ensure_daemon_already_listening_skips_launch/0}.

%% Drain any `launched' messages the mock `LaunchFun' sent and count them.
count_launches() ->
    receive
        launched -> 1 + count_launches()
    after 0 ->
        0
    end.

%% Poll until a `{local, Path}' connect succeeds, so the probe lands on a live
%% listener rather than racing the bind.
wait_listening(_Path, 0) ->
    {error, giving_up};
wait_listening(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {packet, 4}, {active, false}]) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            ok;
        {error, _} ->
            timer:sleep(25),
            wait_listening(Path, N - 1)
    end.

%% AF_UNIX socket paths are bounded by sun_path (~104 bytes on macOS). Use a
%% short, unique-across-BEAM-runs path under the system temp dir, pre-deleting
%% any leftover so the slate is clean.
socket_path() ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_cli7b_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
