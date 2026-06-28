-module(soma_cli_9_stop_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_stop_returns_stopped_result/1]).
-export([test_after_stop_fresh_connect_fails/1]).

all() ->
    [test_stop_returns_stopped_result,
     test_after_stop_fresh_connect_fails].

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
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, <<"(stop)">>),
    {ok, _Reply} = gen_tcp:recv(Client, 0, 5000),
    ok = gen_tcp:close(Client),
    %% A fresh connect to the same path must fail -- the daemon no longer accepts.
    {error, _} = connect_fails(Path, 80).

%% --- helpers (mirroring soma_cli_server_SUITE) ---------------------------

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
