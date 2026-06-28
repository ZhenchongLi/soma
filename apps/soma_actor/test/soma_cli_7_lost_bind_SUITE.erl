-module(soma_cli_7_lost_bind_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_daemon_foreground_lost_bind_returns_ok/1]).
-export([test_lost_bind_leaves_original_listener_alive/1]).
-export([test_dispatch_ping_returns_ping_exit_code/1]).
-export([test_dispatch_ping_socket_override_wins/1]).

all() ->
    [test_daemon_foreground_lost_bind_returns_ok,
     test_lost_bind_leaves_original_listener_alive,
     test_dispatch_ping_returns_ping_exit_code,
     test_dispatch_ping_socket_override_wins].

init_per_testcase(_Case, Config) ->
    %% Hermetic config: point SOMA_CONFIG at an absent path so the daemon loads
    %% no real provider and opens no network.
    PrevConfig = os:getenv("SOMA_CONFIG"),
    AbsentConfig = filename:join(?config(priv_dir, Config),
                                 "absent_soma_config_" ++ os:getpid()),
    _ = file:delete(AbsentConfig),
    os:putenv("SOMA_CONFIG", AbsentConfig),
    %% Point the resolver at a unique per-run XDG_RUNTIME_DIR so the ping
    %% dispatch (no `--socket' override) resolves the same socket we boot the
    %% server on, mirroring `soma_cli_dispatch_SUITE'. Saved/restored per case.
    PrevXdg = os:getenv("XDG_RUNTIME_DIR"),
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    XdgDir = filename:join(Tmp,
                           "soma_cli7_xdg_" ++ os:getpid() ++ "_"
                           ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(XdgDir, "x")),
    ResolvedPath = filename:join(XdgDir, "soma.sock"),
    _ = file:delete(ResolvedPath),
    os:putenv("XDG_RUNTIME_DIR", XdgDir),
    [{prev_config, PrevConfig}, {prev_xdg, PrevXdg},
     {resolved_path, ResolvedPath} | Config].

end_per_testcase(_Case, Config) ->
    case ?config(prev_config, Config) of
        false -> os:unsetenv("SOMA_CONFIG");
        Prev -> os:putenv("SOMA_CONFIG", Prev)
    end,
    case ?config(prev_xdg, Config) of
        false -> os:unsetenv("XDG_RUNTIME_DIR");
        PrevXdg -> os:putenv("XDG_RUNTIME_DIR", PrevXdg)
    end,
    _ = file:delete(?config(resolved_path, Config)),
    ok.

%% Criterion 3 (CLI.7): `soma_cli:daemon_foreground(#{socket => Path})' returns
%% `ok' without crashing when `Path' is already bound by another live listener --
%% the lost-bind race. The test boots a winning `soma_cli_server' on Path (a real
%% bound listener), then spawns a child running `daemon_foreground/1' on the same
%% Path. The child's chain runs: `ensure_all_started' -> `soma_actor_sup:start_link'
%% (tolerated) -> `resolve_socket/1' -> `soma_cli_server:start_link/1', whose
%% `unlink_stale/1' sees the winner answer and leaves the path, so the bind fails
%% with `{error, _}'. The fixed `daemon_foreground/1' turns that failure into a
%% clean `ok' return and the child exits, rather than a `badmatch' crash. The child
%% is off the chain only so the test can observe "the call returned and the process
%% exited normally" through a monitor on the child pid -- the same monitor-the-child
%% pattern the CLI.6 daemon suite uses.
test_daemon_foreground_lost_bind_returns_ok(Config) ->
    Path = socket_path(Config),
    %% The winner: a real bound listener on Path.
    {ok, Winner} = soma_cli_server:start_link(#{socket => Path}),
    ok = wait_listening(Path, 80),

    %% The loser: a child runs `daemon_foreground/1' on the already-bound Path.
    Child = spawn(fun() -> soma_cli:daemon_foreground(#{socket => Path}) end),
    ChildRef = monitor(process, Child),

    %% The loser's bind fails and `daemon_foreground/1' returns `ok', so the child
    %% exits normally -- not a `badmatch' crash. A normal exit reason proves the
    %% call returned cleanly instead of crashing on the lost bind.
    receive
        {'DOWN', ChildRef, process, Child, Reason} ->
            normal = Reason
    after 5000 ->
        exit(Child, kill),
        ct:fail(daemon_foreground_lost_bind_did_not_return)
    end,

    %% Tear the winner down: it is linked to this process, so unlink + kill and
    %% clear the socket file.
    unlink(Winner),
    exit(Winner, kill),
    _ = file:delete(Path),
    ok.

%% Criterion 4 (CLI.7): the winner survives the lost race. Same setup as
%% Criterion 3 -- a winning `soma_cli_server' on Path, a loser child running
%% `daemon_foreground/1' on the same Path -- but here the property under test is
%% that the loser's failed bind left the *winner* completely untouched. After the
%% loser's child has exited, the test opens a fresh framed client to Path and runs
%% a `(stop)' round-trip against the winner: a fresh `gen_tcp:connect' succeeds and
%% the winner answers a framed terminal `(result ...)' whose status sub-form is
%% `stopped'. That fresh connect + answered request, observed from a brand-new
%% connection, proves the winner kept serving Path through the lost race.
test_lost_bind_leaves_original_listener_alive(Config) ->
    Path = socket_path(Config),
    %% The winner: a real bound listener on Path.
    {ok, Winner} = soma_cli_server:start_link(#{socket => Path}),
    ok = wait_listening(Path, 80),
    WinnerRef = monitor(process, Winner),

    %% The loser: a child runs `daemon_foreground/1' on the already-bound Path,
    %% loses the bind, and exits cleanly.
    Child = spawn(fun() -> soma_cli:daemon_foreground(#{socket => Path}) end),
    ChildRef = monitor(process, Child),
    receive
        {'DOWN', ChildRef, process, Child, normal} -> ok
    after 5000 ->
        exit(Child, kill),
        unlink(Winner),
        exit(Winner, kill),
        ct:fail(daemon_foreground_lost_bind_did_not_return)
    end,

    %% The winner is untouched: a brand-new framed client connects to Path and
    %% the winner answers a `(stop)' round-trip with a `(status stopped)' result.
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The winner answers the fresh `(stop)' with a `(status stopped)' result --
    %% it kept serving Path through the loser's lost bind, untouched.
    match = re:run(Reply, "\\(status stopped\\)", [{capture, none}]),
    gen_tcp:close(Client),

    %% The `(stop)' tore the winner down; reap its monitor so the linked process
    %% is gone, then clear the socket file.
    receive
        {'DOWN', WinnerRef, process, Winner, _} -> ok
    after 5000 ->
        unlink(Winner),
        exit(Winner, kill)
    end,
    _ = file:delete(Path),
    ok.

%% Criterion 5 (CLI.7): `soma_cli_main:dispatch(["__ping"])' drives
%% `soma_cli:ping/1' over the resolved socket and returns its exit code. The
%% dispatcher resolves the socket itself (no `--socket' override) through the
%% per-run `XDG_RUNTIME_DIR' the resolver points at. With a live
%% `soma_cli_server' bound on that path the probe connect succeeds and the
%% dispatch returns 0 (mirroring `ping/1''s listening case); after the listener
%% is torn down the connect is refused and the dispatch returns 1 (mirroring
%% `ping/1''s no-listener case). The two returns prove the dispatcher routed the
%% wrapper-internal `__ping' verb through `ping/1' on the resolved socket.
test_dispatch_ping_returns_ping_exit_code(Config) ->
    Path = ?config(resolved_path, Config),
    %% A live listener on the resolved path: the probe connect must succeed.
    {ok, Server} = soma_cli_server:start_link(#{socket => Path}),
    ok = wait_listening(Path, 80),

    %% The dispatcher resolves the socket itself (no `--socket') and lands on the
    %% live listener, so `ping/1' returns 0.
    0 = soma_cli_main:dispatch(["__ping"]),

    %% Tear the listener down: it is linked to this process, so unlink + kill and
    %% clear the socket file so a fresh connect is refused.
    unlink(Server),
    exit(Server, kill),
    _ = file:delete(Path),
    ok = wait_for_connect_refused(Path, 100),

    %% With nothing listening the probe connect is refused, so `ping/1' returns 1.
    1 = soma_cli_main:dispatch(["__ping"]),
    ok.

%% Criterion 6 (CLI.7): `soma_cli_main:dispatch(["__ping", "--socket", Path])'
%% honours a trailing `--socket' override -- the probe connects to the override
%% path, not the resolver's. The test boots a live `soma_cli_server' on a second
%% per-run `OverridePath' while the resolver's `XDG_RUNTIME_DIR/soma.sock' (the
%% per-case resolved path) deliberately has no listener. The dispatch then
%% returns 0, which can only happen if the `--socket' override beat the resolver:
%% had the dispatcher used the resolved path, the probe connect would have been
%% refused and `ping/1' would return 1. The same proof shape
%% `test_dispatch_socket_override_wins' uses in `soma_cli_dispatch_SUITE'.
test_dispatch_ping_socket_override_wins(Config) ->
    %% A second per-run socket, distinct from the resolver's `soma.sock', so
    %% reaching it proves the `--socket' override beat the resolver.
    OverridePath = socket_path(Config),
    {ok, Server} = soma_cli_server:start_link(#{socket => OverridePath}),
    ok = wait_listening(OverridePath, 80),

    %% The resolver's path deliberately has no listener; if the override is
    %% ignored the probe connect lands here and is refused.
    ResolvedPath = ?config(resolved_path, Config),
    false = (OverridePath =:= ResolvedPath),
    _ = file:delete(ResolvedPath),

    %% The dispatch probes the override path (not the resolver), so `ping/1'
    %% connects to the live listener and returns 0.
    1 = soma_cli_main:dispatch(["__ping", "--socket", OverridePath]),

    %% Tear the override listener down: it is linked to this process.
    unlink(Server),
    exit(Server, kill),
    _ = file:delete(OverridePath),
    ok.

%% --- helpers (mirroring the sibling daemon suites) -----------------------

%% Bounded poll: returns ok once a `{local, Path}' connect is refused (the
%% listener has torn down), retrying up to `N' times with a short sleep between.
wait_for_connect_refused(_Path, 0) ->
    {error, still_listening};
wait_for_connect_refused(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {packet, 4}, {active, false}]) of
        {ok, Sock} ->
            ok = gen_tcp:close(Sock),
            timer:sleep(20),
            wait_for_connect_refused(Path, N - 1);
        {error, _} ->
            ok
    end.

%% Poll until a `{local, Path}' connect succeeds, so the loser races a live
%% listener rather than racing the winner's bind.
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

%% Open a framed client to a live listener, bounded-polling the connect so the
%% fresh client races the winner's accept rather than a not-yet-ready socket.
connect(Path) -> connect(Path, 80).
connect(_Path, 0) ->
    {error, giving_up};
connect(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {packet, 4}, {active, false}]) of
        {ok, Sock} ->
            {ok, Sock};
        {error, _} ->
            timer:sleep(25),
            connect(Path, N - 1)
    end.

%% AF_UNIX socket paths are bounded by sun_path (~104 bytes on macOS). Use a
%% short, unique-across-BEAM-runs path under the system temp dir, pre-deleting
%% any leftover so the slate is clean.
socket_path(_Config) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_cli7_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
