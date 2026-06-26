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
-export([test_run_lisp_echo_returns_completed_result/1]).
-export([test_run_lisp_result_carries_correlation_id/1]).
-export([test_run_lisp_failed_returns_error_result/1]).
-export([test_server_serves_after_failed_lisp_run/1]).

all() ->
    [test_start_link_listens_and_accepts_connect,
     test_start_link_unlinks_stale_socket_file,
     test_second_start_link_on_live_path_errors,
     test_first_server_survives_failed_second_start_link,
     test_run_echo_returns_completed_with_outputs,
     test_run_failed_returns_failed_with_error,
     test_server_serves_after_failed_run,
     test_run_lisp_echo_returns_completed_result,
     test_run_lisp_result_carries_correlation_id,
     test_run_lisp_failed_returns_error_result,
     test_server_serves_after_failed_lisp_run].

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

%% Criterion 1 (CLI.1b): a framed Lisp `(run (step ...))' request carrying a
%% one-step `echo' workflow drives the real server -> soma_lfe:compile ->
%% soma_run -> soma_tool_call (echo) -> soma_lisp:render path and replies a framed
%% `(result ...)' s-expr whose status sub-form is `completed' and whose outputs
%% sub-form carries step s1's echo value. No layer is bypassed: a real gen_tcp
%% client over the local Unix socket sends the s-expr and reads the s-expr reply.
test_run_lisp_echo_returns_completed_result(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply is an s-expr, not JSON. It must be a `(result ...)' form whose
    %% status sub-form is `completed' and whose outputs carry s1's echo value.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "\\(s1 \\(value \"hi\"\\)\\)", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 2 (CLI.1b): the completed `(result ...)' reply carries a non-empty
%% `(correlation-id "...")' sub-form. Same call chain as Criterion 1 -- a real
%% gen_tcp client over a temp Unix socket sends the framed `(run (step ...))'
%% s-expr -- and the reply's correlation-id sub-form holds a non-empty quoted
%% string (the run's minted correlation id, stamped on every run event).
test_run_lisp_result_carries_correlation_id(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must carry a `(correlation-id "...")' sub-form whose quoted
    %% string is non-empty (at least one character between the quotes).
    match = re:run(Reply, "\\(correlation-id \"[^\"]+\"\\)", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 4 (CLI.1b): a framed Lisp `(run (step ...))' request whose only step
%% uses the `fail' tool drives the real server -> soma_lfe:compile -> soma_run ->
%% soma_tool_call (fail) -> await_run (run_failed) -> soma_lisp:render path and
%% replies a framed `(result ...)' s-expr whose status sub-form is NOT `completed'
%% and which carries an `(error ...)' sub-form. The run's failure is data in the
%% s-expr reply, not a handler crash. A real gen_tcp client over a temp Unix
%% socket sends the s-expr and reads the s-expr reply.
test_run_lisp_failed_returns_error_result(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 fail (args (mode error))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is not
    %% `completed' and which carries an `(error ...)' sub-form.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    nomatch = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "\\(error ", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 5 (CLI.1b): the server stays up after a failed Lisp run and answers
%% the next request on a new connection. The first connection sends a `(run (step
%% ...))' whose only step uses the `fail' tool (the Criterion 4 chain), failing the
%% run; the second connection (a fresh socket) sends an echo `(run (step ...))'
%% (the Criterion 1 chain) and reads a `(result ...)' s-expr whose status sub-form
%% is `completed'. The proof is that the same server process serves a second
%% well-formed request after a failed run -- it did not crash with the failed run.
test_server_serves_after_failed_lisp_run(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, C1} = connect(Path),
    Fail = <<"(run (step s1 fail (args (mode error))))">>,
    ok = gen_tcp:send(C1, Fail),
    {ok, _} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    {ok, C2} = connect(Path),
    Echo = <<"(run (step s1 echo (args (value \"ok\"))))">>,
    ok = gen_tcp:send(C2, Echo),
    {ok, Reply} = gen_tcp:recv(C2, 0, 5000),
    %% The second reply must be a completed `(result ...)' -- the server survived
    %% the earlier failed run and served this fresh well-formed request.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status failed\\)", [{capture, none}]),
    ok = gen_tcp:close(C2).

%% A small defensive retry for the client connect: right after start_link the
%% accept loop may not have reached gen_tcp:accept yet, so a connect can briefly
%% see econnrefused. (The eopnotsupp "flake" this once seemed to address was
%% actually a socket_path collision across BEAM runs, now fixed in socket_path/1.)
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
%%
%% os:getpid() makes the path unique ACROSS BEAM runs. erlang:unique_integer
%% resets every run, so without the pid, repeated `rebar3 ct' invocations (which
%% relay's tdd-check does, plus its retry) regenerate the same low-numbered paths
%% and collide with the socket files earlier runs left behind -- and
%% file:write_file onto a leftover socket file fails with eopnotsupp on macOS,
%% which was the real source of the "flaky" stale-socket test. The pre-delete
%% clears any leftover at the (now unique) path so the slate is always clean.
socket_path(_Config) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_cli_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
