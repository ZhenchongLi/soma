-module(soma_cli_6_foreground_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_daemon_foreground_serves_stop_then_returns/1]).

all() ->
    [test_daemon_foreground_serves_stop_then_returns].

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

%% Criterion 1 (CLI.6): `soma_cli:daemon_foreground(#{socket => Path})' boots a
%% daemon a client can connect to on `Path', serves a framed `(stop)' that replies
%% `(result (status stopped))', and then returns -- the separate child process
%% running the call must terminate after the stop, proving the daemon BEAM exits
%% cleanly instead of lingering. The full chain runs: a child runs
%% `daemon_foreground/1' (boot + block on listener monitor), a real `gen_tcp'
%% client sends framed `(stop)' over the socket, the server accept loop -> handler
%% -> stop path closes the listen socket and replies stopped, the listener exits,
%% the monitor `DOWN' fires, `daemon_foreground/1' returns, and the child dies. The
%% child's termination is observed off-chain through a monitor on the child pid,
%% because "the call returned and the process exited" is the property under test.
test_daemon_foreground_serves_stop_then_returns(Config) ->
    Path = socket_path(Config),
    Child = spawn(fun() -> soma_cli:daemon_foreground(#{socket => Path}) end),
    ChildRef = monitor(process, Child),

    %% The daemon must come up: a real client can connect on Path.
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply is the terminal `(result ...)' s-expr whose status is `stopped'.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status stopped\\)", [{capture, none}]),
    ok = gen_tcp:close(Client),

    %% The child running `daemon_foreground/1' must terminate after the stop --
    %% the call returned and the process exited (the daemon BEAM does not linger).
    receive
        {'DOWN', ChildRef, process, Child, _Reason} ->
            ok
    after 5000 ->
        exit(Child, kill),
        ct:fail(daemon_foreground_did_not_return)
    end.

%% --- helpers (mirroring the sibling daemon suites) -----------------------

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
    Name = "soma_cli6_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
