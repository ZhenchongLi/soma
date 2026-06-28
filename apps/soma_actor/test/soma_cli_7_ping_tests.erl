-module(soma_cli_7_ping_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #147 criterion 1 (CLI.7): `soma_cli:ping(#{socket => Path})' is the
%% liveness probe. It resolves the socket the same way the other `soma_cli'
%% client funcs do, connects with `gen_tcp:connect({local, Path}, ...)', closes
%% immediately (sends no request), and returns an integer exit code -- `0' when a
%% `soma_cli_server' is listening on `Path'. This test boots a real listener on a
%% unique-per-run socket path and asserts the probe returns `0'.
test_ping_returns_zero_when_listening() ->
    Path = socket_path(),
    {ok, Server} = soma_cli_server:start_link(#{socket => Path}),
    try
        %% Wait until the listener is actually accepting before probing.
        ok = wait_listening(Path, 80),
        ?assertEqual(0, soma_cli:ping(#{socket => Path}))
    after
        %% The listener is linked to this process; unlink + kill it and clear the
        %% socket file so the shared EUnit node is left clean.
        unlink(Server),
        exit(Server, kill),
        _ = file:delete(Path)
    end.

ping_returns_zero_when_listening_test_() ->
    {timeout, 30, fun test_ping_returns_zero_when_listening/0}.

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
    Name = "soma_cli7_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
