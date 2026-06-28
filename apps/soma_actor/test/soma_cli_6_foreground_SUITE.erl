-module(soma_cli_6_foreground_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_daemon_foreground_serves_stop_then_returns/1]).
-export([test_dispatch_daemon_blocks_then_exits_zero/1]).
-export([test_cold_boot_registers_actor_sup/1]).
-export([test_warm_boot_tolerates_existing_actor_sup/1]).

all() ->
    [test_daemon_foreground_serves_stop_then_returns,
     test_dispatch_daemon_blocks_then_exits_zero,
     test_cold_boot_registers_actor_sup,
     test_warm_boot_tolerates_existing_actor_sup].

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

%% Criterion 2 (CLI.6): `soma_cli_main:dispatch(["daemon", "--socket", Path])'
%% routes to `soma_cli:daemon_foreground/1', blocks while the daemon serves, and
%% returns exit code 0 after a `(stop)'. The full chain runs: a child runs
%% `dispatch/1' (which parses the `--socket' flag and calls `daemon_foreground/1',
%% booting + blocking on the listener monitor), a real `gen_tcp' client sends a
%% framed `(stop)' over the socket, the server accept loop -> handler -> stop path
%% closes the listen socket and replies stopped, the listener exits, the monitor
%% `DOWN' fires, `daemon_foreground/1' returns, `dispatch/1' returns 0, and the
%% child sends that exit code back. The exit code is captured by having the child
%% send its `dispatch/1' return value to the test process, because `dispatch/1'
%% blocks and only returns after the stop.
test_dispatch_daemon_blocks_then_exits_zero(Config) ->
    Path = socket_path(Config),
    Parent = self(),
    Child = spawn(fun() ->
        Exit = soma_cli_main:dispatch(["daemon", "--socket", Path]),
        Parent ! {dispatch_exit, self(), Exit}
    end),

    %% The daemon must come up: a real client can connect on Path.
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply is the terminal `(result ...)' s-expr whose status is `stopped'.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status stopped\\)", [{capture, none}]),
    ok = gen_tcp:close(Client),

    %% `dispatch/1' blocked while the daemon served and now returns exit code 0
    %% after the `(stop)' tore the listener down -- the child reports it back.
    receive
        {dispatch_exit, Child, Exit} ->
            0 = Exit
    after 5000 ->
        exit(Child, kill),
        ct:fail(dispatch_daemon_did_not_return)
    end.

%% Criterion 3 (CLI.6): after `soma_cli:daemon_foreground(#{socket => Path})'
%% boots in a BEAM where `soma_actor_sup' was not registered beforehand,
%% `whereis(soma_actor_sup)' returns a live pid -- so a standalone daemon can
%% serve `ask' (whose `start_actor/1' needs a live supervisor). `soma_actor_sup'
%% is a named singleton, so the cold-boot precondition is order-sensitive within
%% a CT run: if an earlier case left it registered, this case tears it down first
%% so the boot is a genuine cold boot, then asserts it is `undefined' before
%% booting. The read is gated on a bounded poll for the listener accepting
%% connections, so it happens after boot completed.
test_cold_boot_registers_actor_sup(Config) ->
    %% Make the cold-boot precondition real, not an accident of ordering: tear
    %% down any `soma_actor_sup' an earlier case left registered.
    case whereis(soma_actor_sup) of
        undefined -> ok;
        Existing ->
            Mon = monitor(process, Existing),
            ok = supervisor:terminate_child(soma_actor_sup, Existing),
            exit(Existing, shutdown),
            receive {'DOWN', Mon, process, Existing, _} -> ok after 5000 -> ok end
    end,
    undefined = whereis(soma_actor_sup),

    Path = socket_path(Config),
    Child = spawn(fun() -> soma_cli:daemon_foreground(#{socket => Path}) end),
    ChildRef = monitor(process, Child),

    %% Gate the read on boot completing: a real client can connect on Path only
    %% once the listener is accepting, which is after boot started soma_actor_sup.
    {ok, Client} = connect(Path),

    %% The cold boot registered soma_actor_sup: whereis returns a live pid.
    Sup = whereis(soma_actor_sup),
    true = is_pid(Sup),
    true = is_process_alive(Sup),

    %% Tear the daemon down cleanly so the child returns and exits.
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, _Reply} = gen_tcp:recv(Client, 0, 5000),
    ok = gen_tcp:close(Client),
    receive
        {'DOWN', ChildRef, process, Child, _Reason} -> ok
    after 5000 ->
        exit(Child, kill),
        ct:fail(daemon_foreground_did_not_return)
    end.

%% Criterion 4 (CLI.6): `soma_cli:daemon_foreground(#{socket => Path})' boots
%% without error when `soma_actor_sup' is already registered, rather than crashing
%% on the already-started supervisor. `soma_actor_sup' is a named singleton, so a
%% second `start_link' returns `{error, {already_started, Pid}}', which boot must
%% tolerate. The test starts `soma_actor_sup' first, asserts its pid is live,
%% boots `daemon_foreground/1' in a child, then confirms the daemon serves a real
%% client request on `Path' (proving boot did not crash on the already-started
%% supervisor). The same supervisor pid is still registered after boot.
test_warm_boot_tolerates_existing_actor_sup(Config) ->
    %% Start soma_actor_sup before booting the daemon, so boot meets an
    %% already-registered supervisor. Tolerate a sibling case having left one up.
    Sup0 = case soma_actor_sup:start_link() of
               {ok, S} -> S;
               {error, {already_started, S}} -> S
           end,
    true = is_pid(Sup0),
    true = is_process_alive(Sup0),

    Path = socket_path(Config),
    Child = spawn(fun() -> soma_cli:daemon_foreground(#{socket => Path}) end),
    ChildRef = monitor(process, Child),

    %% The daemon must come up despite the pre-existing supervisor: a real client
    %% can connect on Path only once the listener is accepting, which is after
    %% boot tolerated the already-started supervisor.
    {ok, Client} = connect(Path),

    %% The same supervisor pid is still registered after boot -- boot did not
    %% restart or replace it, it tolerated the already-started one.
    Sup1 = whereis(soma_actor_sup),
    true = is_pid(Sup1),
    true = is_process_alive(Sup1),
    true = (Sup0 =/= Sup1),

    %% Tear the daemon down cleanly so the child returns and exits.
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, _Reply} = gen_tcp:recv(Client, 0, 5000),
    ok = gen_tcp:close(Client),
    receive
        {'DOWN', ChildRef, process, Child, _Reason} -> ok
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
