-module(soma_cli_9_stop_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_stop_returns_stopped_result/1]).
-export([test_after_stop_fresh_connect_fails/1]).
-export([test_after_stop_socket_file_gone/1]).
-export([test_after_stop_start_link_rebinds_path/1]).
-export([test_stop_cancels_active_detached_run/1]).
-export([test_stop_kills_active_detached_tool_worker/1]).

all() ->
    [test_stop_returns_stopped_result,
     test_after_stop_fresh_connect_fails,
     test_after_stop_socket_file_gone,
     test_after_stop_start_link_rebinds_path,
     test_stop_cancels_active_detached_run,
     test_stop_kills_active_detached_tool_worker].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    Sup = case soma_actor_sup:start_link() of
              {ok, Pid} -> Pid;
              {error, {already_started, Pid}} -> Pid
          end,
    [{started_apps, Started}, {actor_sup, Sup} | Config].

end_per_testcase(_Case, Config) ->
    Config.

%% Criterion 2 (CLI.9): a framed `(stop)' request to a running daemon drives the
%% real server -> accept_loop -> handler -> handle_lisp_request -> soma_lfe:compile
%% (stop) -> stop handler -> soma_lisp render path and replies a framed terminal
%% `(result ...)' s-expr whose status sub-form is `stopped'. A real gen_tcp client
%% over a temp Unix socket sends the framed `(stop)' and reads the framed reply --
%% no layer is bypassed.
test_stop_returns_stopped_result(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    ok = wait_for_registry_ready(100),
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is `stopped'.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status stopped\\)", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 3 (CLI.9): after a `(stop)' the daemon stops accepting connections.
%% A real client sends framed `(stop)' and reads the terminal reply; the handler
%% signals the listener to close the listen socket, ending the accept loop. A
%% fresh `gen_tcp:connect' to the same path must then error -- nothing is
%% listening. We poll (bounded) because the close races the reply read.
test_after_stop_fresh_connect_fails(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    ok = wait_for_registry_ready(100),
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, _Reply} = gen_tcp:recv(Client, 0, 5000),
    ok = gen_tcp:close(Client),
    %% A fresh connect to the same path must fail -- the daemon no longer accepts.
    {error, _} = connect_fails(Path, 80).

%% Criterion 4 (CLI.9): after a `(stop)' the daemon also unlinks its socket file
%% from disk -- closing the listen socket frees the descriptor, but the AF_UNIX
%% path lingers as a leftover file unless the listener removes it. A real client
%% sends framed `(stop)' and reads the terminal reply; we then poll (bounded)
%% `file:read_file_info/1' on the path until it reports `{error, enoent}'. This
%% off-chain file check is the only way to observe the unlink -- it is not on the
%% reply path -- so the poll covers the race between the reply read and the
%% listener's teardown.
test_after_stop_socket_file_gone(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    ok = wait_for_registry_ready(100),
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, _Reply} = gen_tcp:recv(Client, 0, 5000),
    ok = gen_tcp:close(Client),
    %% The socket file at Path must be gone from disk after the stop.
    {error, enoent} = file_gone(Path, 80).

%% Criterion 5 (CLI.9): after a `(stop)' a fresh `soma_cli_server:start_link/1' on
%% the *same* path must bind successfully -- the proof that both the listen socket
%% and the AF_UNIX socket file were released, not just made unreachable. A real
%% client sends framed `(stop)' and reads the terminal reply; we then poll
%% (bounded) a fresh `start_link/1' on the same path until it returns `{ok, _}'
%% (the teardown races the reply read), and confirm the new server actually
%% listens with a `{local, _}' connect.
test_after_stop_start_link_rebinds_path(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    ok = wait_for_registry_ready(100),
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, _Reply} = gen_tcp:recv(Client, 0, 5000),
    ok = gen_tcp:close(Client),
    %% A fresh start_link on the same path must bind, proving the path is free.
    {ok, _Rebound} = rebind(Path, 80),
    %% And the rebound server must actually be listening on that path.
    {ok, NewClient} = connect(Path),
    ok = gen_tcp:close(NewClient).

%% Criterion 6 (CLI.9): a detached run that is still active when `(stop)' arrives
%% must reach a terminal `cancelled' state. Stop cancels in-flight detached runs
%% rather than refusing while busy. A real client starts a detached long `sleep'
%% over the socket, reads the `(accepted ...)' task id, waits (bounded) for that
%% run's `tool.started' so the run is live, then sends `(stop)' on a fresh
%% connection. The stop handler asks the daemon-owned registry to cancel every
%% running task, `soma_run' tears down and emits `run.cancelled'. We poll the
%% event store (the same observation seam the cancel cases use) for
%% `run.cancelled' on that run id.
test_stop_cancels_active_detached_run(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    running = wait_for_registry_status(TaskId, running, 100),
    {ok, #{run_id := RunId}} = soma_cli_task_registry:lookup(TaskId),
    %% Wait for `tool.started' so the stop lands while the sleep worker is live.
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),

    {ok, C2} = connect(Path),
    ok = gen_tcp:send(C2, <<"(stop)">>),
    {ok, _StopReply} = gen_tcp:recv(C2, 0, 5000),
    ok = gen_tcp:close(C2),
    %% The active detached run must reach `cancelled' -- a `run.cancelled' event
    %% for that run id must land in the store.
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, Event) || Event <- Events],
    true = lists:member(<<"run.cancelled">>, Types).

%% Criterion 7 (CLI.9): the tool-call worker of a detached run that is still
%% active when `(stop)' arrives must be dead after the stop. The cancel path's
%% brutal `exit(WorkerPid, kill)' is what makes cancellation real -- not a flag
%% checked at the end -- so the worker process must genuinely be gone. Same
%% real-socket detached-run setup as Criterion 6: a client starts a detached long
%% `sleep', we wait (bounded) for the run's `tool.started' and read the worker pid
%% off that event (`tool_call_pid' is not on the reply path, so the event store is
%% the only seam), send `(stop)', wait for `run.cancelled', then assert
%% `is_process_alive/1' on the captured worker pid is `false'.
test_stop_kills_active_detached_tool_worker(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    running = wait_for_registry_status(TaskId, running, 100),
    {ok, #{run_id := RunId}} = soma_cli_task_registry:lookup(TaskId),
    %% Wait for `tool.started' so the worker is live, then read its pid.
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),
    WorkerPid = tool_call_pid(StorePid, RunId),
    true = is_pid(WorkerPid),

    {ok, C2} = connect(Path),
    ok = gen_tcp:send(C2, <<"(stop)">>),
    {ok, _StopReply} = gen_tcp:recv(C2, 0, 5000),
    ok = gen_tcp:close(C2),
    %% The detached run must reach `cancelled' -- once that lands, the cancel
    %% path has already killed the worker.
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    %% The worker process of that detached run must be dead after the stop.
    false = is_process_alive(WorkerPid).

%% --- helpers (mirroring soma_cli_server_SUITE) ---------------------------

%% Read the worker pid off the run's `tool.started' event in the store.
tool_call_pid(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    [Started | _] =
        [E || E <- Events, maps:get(event_type, E) =:= <<"tool.started">>],
    maps:get(tool_call_pid, Started).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

%% Poll the run-scoped trail until the given event type appears.
wait_for_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(Type, Types) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_event(StorePid, RunId, Type, N - 1)
    end.

wait_for_registry_status(TaskId, _Expected, 0) ->
    {ok, Task} = soma_cli_task_registry:lookup(TaskId),
    maps:get(status, Task);
wait_for_registry_status(TaskId, Expected, N) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, #{status := Expected}} ->
            Expected;
        {ok, _Task} ->
            timer:sleep(20),
            wait_for_registry_status(TaskId, Expected, N - 1);
        {error, not_found} ->
            timer:sleep(20),
            wait_for_registry_status(TaskId, Expected, N - 1);
        {error, recovery_incomplete} ->
            timer:sleep(20),
            wait_for_registry_status(TaskId, Expected, N - 1)
    end.

wait_for_registry_ready(0) ->
    {error, recovery_timeout};
wait_for_registry_ready(N) ->
    case soma_cli_task_registry:lookup(<<"__recovery_probe__">>) of
        {error, recovery_incomplete} ->
            timer:sleep(20),
            wait_for_registry_ready(N - 1);
        _ ->
            ok
    end.

%% Poll for the path becoming rebindable. While the old listener has not yet torn
%% down (raced against the reply read), a fresh `start_link/1' would land on a
%% still-live path; keep retrying until it returns `{ok, _}' or the budget runs
%% out. The probe-based `unlink_stale/1' in the server only clears a *stale* file,
%% so a successful bind here means the old server genuinely released the path.
rebind(_Path, 0) ->
    {error, giving_up};
rebind(Path, N) ->
    case soma_cli_server:start_link(#{socket => Path}) of
        {ok, _Pid} = Ok ->
            Ok;
        {error, _} ->
            timer:sleep(25),
            rebind(Path, N - 1)
    end.

%% Poll for the socket file being unlinked. While `file:read_file_info/1' still
%% reports the file present, the listener has not unlinked yet, so keep waiting
%% until it errors (`enoent') or the budget runs out.
file_gone(Path, 0) ->
    file:read_file_info(Path);
file_gone(Path, N) ->
    case file:read_file_info(Path) of
        {ok, _} ->
            timer:sleep(25),
            file_gone(Path, N - 1);
        {error, _} = Err ->
            Err
    end.

%% Poll for the listen socket being gone: a single (non-retrying) connect that
%% keeps succeeding means the daemon is still accepting, so keep waiting until
%% it errors or the budget runs out.
connect_fails(_Path, 0) ->
    {ok, still_accepting};
connect_fails(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {packet, 4}, {active, false}], 200) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            timer:sleep(25),
            connect_fails(Path, N - 1);
        {error, _} = Err ->
            Err
    end.

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
    Name = "soma_cli9_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
