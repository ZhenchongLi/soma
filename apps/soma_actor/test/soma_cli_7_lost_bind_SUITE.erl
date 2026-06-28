-module(soma_cli_7_lost_bind_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_daemon_foreground_lost_bind_returns_ok/1]).

all() ->
    [test_daemon_foreground_lost_bind_returns_ok].

init_per_testcase(_Case, Config) ->
    %% Hermetic config: point SOMA_CONFIG at an absent path so the daemon loads
    %% no real provider and opens no network.
    PrevConfig = os:getenv("SOMA_CONFIG"),
    AbsentConfig = filename:join(?config(priv_dir, Config),
                                 "absent_soma_config_" ++ os:getpid()),
    _ = file:delete(AbsentConfig),
    os:putenv("SOMA_CONFIG", AbsentConfig),
    [{prev_config, PrevConfig} | Config].

end_per_testcase(_Case, Config) ->
    case ?config(prev_config, Config) of
        false -> os:unsetenv("SOMA_CONFIG");
        Prev -> os:putenv("SOMA_CONFIG", Prev)
    end,
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

%% --- helpers (mirroring the sibling daemon suites) -----------------------

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
