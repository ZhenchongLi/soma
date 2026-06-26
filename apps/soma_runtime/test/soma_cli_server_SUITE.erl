-module(soma_cli_server_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_start_link_listens_and_accepts_connect/1]).
-export([test_start_link_unlinks_stale_socket_file/1]).
-export([test_second_start_link_on_live_path_errors/1]).
-export([test_first_server_survives_failed_second_start_link/1]).
-export([test_run_echo_returns_completed_with_outputs/1]).
-export([test_run_failed_returns_failed_with_error/1]).
-export([test_server_serves_after_failed_run/1]).

all() ->
    [test_start_link_listens_and_accepts_connect,
     test_start_link_unlinks_stale_socket_file,
     test_second_start_link_on_live_path_errors,
     test_first_server_survives_failed_second_start_link,
     test_run_echo_returns_completed_with_outputs,
     test_run_failed_returns_failed_with_error,
     test_server_serves_after_failed_run].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, Config) ->
    Config.

%% Criterion 4: start_link(#{socket => Path}) leaves a listening socket file at
%% Path that an Erlang gen_tcp client can connect to.
test_start_link_listens_and_accepts_connect(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

%% Criterion 5: a leftover file at Path (e.g. a stale socket left by a crashed
%% server) does not stop start_link -- the stale file is unlinked before bind,
%% so the listener binds and accepts a connect.
test_start_link_unlinks_stale_socket_file(Config) ->
    Path = socket_path(Config),
    ok = file:write_file(Path, <<"stale">>),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

%% Criterion 6: a second start_link on a Path already served by a live server
%% returns an error (the bind cannot take the in-use address) and does not start
%% a duplicate listener -- the live server's path is not stolen, so server A is
%% the single listener and still answers a connect.
test_second_start_link_on_live_path_errors(Config) ->
    Path = socket_path(Config),
    {ok, ServerA} = soma_cli_server:start_link(#{socket => Path}),
    {error, _Reason} = soma_cli_server:start_link(#{socket => Path}),
    true = is_process_alive(ServerA),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

%% Criterion 7: after a second start_link on server A's live path fails, server A
%% keeps serving -- the failed second bind did not disturb A's listener, so a
%% fresh client still connects to A.
test_first_server_survives_failed_second_start_link(Config) ->
    Path = socket_path(Config),
    {ok, ServerA} = soma_cli_server:start_link(#{socket => Path}),
    {error, _Reason} = soma_cli_server:start_link(#{socket => Path}),
    true = is_process_alive(ServerA),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

%% Criterion 8: a framed `run' request carrying a one-step `echo' workflow drives
%% the real server -> run -> tool-call path and returns a framed response with
%% status "completed", a non-empty task_id, a non-empty correlation_id, and an
%% `outputs' object holding the echo step's result. No layer is bypassed: a real
%% gen_tcp client over the local Unix socket sends the request and reads the reply.
test_run_echo_returns_completed_with_outputs(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = #{<<"cmd">> => <<"run">>,
                <<"workflow">> =>
                    [#{<<"id">> => <<"s1">>,
                       <<"tool">> => <<"echo">>,
                       <<"args">> => #{<<"value">> => <<"hi">>}}]},
    ok = gen_tcp:send(Client, iolist_to_binary(json:encode(Request))),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    Response = json:decode(Reply),
    <<"completed">> = maps:get(<<"status">>, Response),
    TaskId = maps:get(<<"task_id">>, Response),
    true = is_binary(TaskId) andalso byte_size(TaskId) > 0,
    CorrId = maps:get(<<"correlation_id">>, Response),
    true = is_binary(CorrId) andalso byte_size(CorrId) > 0,
    Outputs = maps:get(<<"outputs">>, Response),
    #{<<"value">> := <<"hi">>} = maps:get(<<"s1">>, Outputs),
    ok = gen_tcp:close(Client).

%% Criterion 9: a `run' request whose step fails returns a framed response with a
%% status other than "completed" and an `error' field -- the run's failure is data
%% in the response, not a handler crash (the `fail' tool's step fails the run).
test_run_failed_returns_failed_with_error(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = #{<<"cmd">> => <<"run">>,
                <<"workflow">> =>
                    [#{<<"id">> => <<"s1">>,
                       <<"tool">> => <<"fail">>,
                       <<"args">> => #{<<"mode">> => <<"error">>}}]},
    ok = gen_tcp:send(Client, iolist_to_binary(json:encode(Request))),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    Response = json:decode(Reply),
    true = maps:get(<<"status">>, Response) =/= <<"completed">>,
    true = maps:is_key(<<"error">>, Response),
    ok = gen_tcp:close(Client).

%% Criterion 10: the server keeps serving after a failed run -- a fresh client
%% gets a completed `echo' run after an earlier request whose step failed.
test_server_serves_after_failed_run(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, C1} = connect(Path),
    Fail = #{<<"cmd">> => <<"run">>,
             <<"workflow">> => [#{<<"id">> => <<"s1">>, <<"tool">> => <<"fail">>,
                                  <<"args">> => #{<<"mode">> => <<"error">>}}]},
    ok = gen_tcp:send(C1, iolist_to_binary(json:encode(Fail))),
    {ok, _} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    {ok, C2} = connect(Path),
    Echo = #{<<"cmd">> => <<"run">>,
             <<"workflow">> => [#{<<"id">> => <<"s1">>, <<"tool">> => <<"echo">>,
                                  <<"args">> => #{<<"value">> => <<"ok">>}}]},
    ok = gen_tcp:send(C2, iolist_to_binary(json:encode(Echo))),
    {ok, Reply} = gen_tcp:recv(C2, 0, 5000),
    <<"completed">> = maps:get(<<"status">>, json:decode(Reply)),
    ok = gen_tcp:close(C2).

%% A retrying client connect. AF_UNIX `connect' on macOS can transiently return
%% `eopnotsupp'/`econnrefused' under heavy load (the kernel briefly rejects, or
%% the listener is mid-bind); retry a few times so the suite is deterministic.
%% The server itself is fine -- this only smooths the client side.
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

%% AF_UNIX socket paths are bounded by sun_path (~104 bytes on macOS), so the
%% long CT priv_dir cannot hold a bindable socket. Use a short unique path
%% under the system temp dir.
socket_path(_Config) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_cli_" ++ integer_to_list(erlang:unique_integer([positive]))
           ++ ".sock",
    filename:join(Tmp, Name).
