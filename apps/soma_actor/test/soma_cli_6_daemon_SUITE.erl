-module(soma_cli_6_daemon_SUITE).

%% CLI.6: the packaged `soma daemon' lifecycle. `soma_cli:daemon_foreground/1'
%% boots the daemon and blocks until its listener terminates, so the BEAM the
%% `soma daemon' wrapper launches stays alive while serving and exits cleanly the
%% moment `soma stop' tears the listener down. `soma_cli_main:dispatch(["daemon"
%% | _])' routes to it and returns 0 once the daemon has stopped.
%%
%% Hermetic: `SOMA_CONFIG' is pointed at an absent path so the daemon loads no
%% real `~/.soma/config' and runs the mock decision path -- no network.

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_daemon_foreground_serves_then_returns_on_stop/1]).
-export([test_dispatch_daemon_returns_zero_after_stop/1]).

all() ->
    [test_daemon_foreground_serves_then_returns_on_stop,
     test_dispatch_daemon_returns_zero_after_stop].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    Sup = case soma_actor_sup:start_link() of
              {ok, Pid} -> Pid;
              {error, {already_started, Pid}} -> Pid
          end,
    %% Point config resolution at an absent path so the daemon loads no real
    %% provider config and runs the hermetic mock path.
    true = os:putenv("SOMA_CONFIG", "/nonexistent/soma-cli6-noconfig"),
    [{started_apps, Started}, {actor_sup, Sup} | Config].

end_per_testcase(_Case, Config) ->
    os:unsetenv("SOMA_CONFIG"),
    Config.

%% `daemon_foreground/1' boots a listener a client can reach (so the daemon is
%% live), serves a framed `(stop)' request (a `(status stopped)' reply proves it
%% processes requests), and then RETURNS -- the `(stop)' teardown ends the
%% listener's accept loop, the monitor observes the `DOWN', and the blocking
%% daemon process exits. A separate daemon process running `daemon_foreground/1'
%% is monitored; after the stop it must go `DOWN', proving the wrapper's BEAM
%% would halt cleanly rather than linger.
test_daemon_foreground_serves_then_returns_on_stop(Config) ->
    Path = socket_path(Config),
    Daemon = spawn(fun() ->
                           ok = soma_cli:daemon_foreground(#{socket => Path})
                   end),
    DRef = erlang:monitor(process, Daemon),
    %% The daemon is up: a client can connect on the resolved path.
    {ok, C0} = connect(Path),
    ok = gen_tcp:close(C0),
    %% It serves requests: `(stop)' returns the terminal `(status stopped)'.
    {ok, C1} = connect(Path),
    ok = gen_tcp:send(C1, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(C1, 0, 5000),
    match = re:run(Reply, "\\(status stopped\\)", [{capture, none}]),
    ok = gen_tcp:close(C1),
    %% The blocking daemon process must now exit -- stop ends the daemon, so the
    %% BEAM the wrapper launched would halt.
    receive
        {'DOWN', DRef, process, Daemon, _Reason} -> ok
    after 5000 ->
        ct:fail(daemon_did_not_exit_after_stop)
    end.

%% `soma_cli_main:dispatch(["daemon", "--socket", Path])' routes to
%% `daemon_foreground/1', blocks while the daemon serves, and returns exit code 0
%% once `soma stop' has torn it down. The dispatch runs in a separate process
%% that reports its return value; after a `(stop)' the dispatch must return 0.
test_dispatch_daemon_returns_zero_after_stop(Config) ->
    Path = socket_path(Config),
    Parent = self(),
    _Daemon = spawn(fun() ->
                            Code = soma_cli_main:dispatch(["daemon", "--socket", Path]),
                            Parent ! {dispatch_done, Code}
                    end),
    {ok, C1} = connect(Path),
    ok = gen_tcp:send(C1, <<"(stop)">>),
    {ok, _Reply} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    receive
        {dispatch_done, Code} -> 0 = Code
    after 5000 ->
        ct:fail(dispatch_daemon_did_not_return)
    end.

%% --- helpers (mirroring soma_cli_9_stop_SUITE) ---------------------------

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
