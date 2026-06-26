-module(soma_cli_server_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_start_link_listens_and_accepts_connect/1]).
-export([test_start_link_unlinks_stale_socket_file/1]).
-export([test_second_start_link_on_live_path_errors/1]).
-export([test_first_server_survives_failed_second_start_link/1]).

all() ->
    [test_start_link_listens_and_accepts_connect,
     test_start_link_unlinks_stale_socket_file,
     test_second_start_link_on_live_path_errors,
     test_first_server_survives_failed_second_start_link].

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
    {ok, Client} = gen_tcp:connect({local, Path}, 0,
                                   [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:close(Client).

%% Criterion 5: a leftover file at Path (e.g. a stale socket left by a crashed
%% server) does not stop start_link -- the stale file is unlinked before bind,
%% so the listener binds and accepts a connect.
test_start_link_unlinks_stale_socket_file(Config) ->
    Path = socket_path(Config),
    ok = file:write_file(Path, <<"stale">>),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = gen_tcp:connect({local, Path}, 0,
                                   [binary, {packet, 4}, {active, false}]),
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
    {ok, Client} = gen_tcp:connect({local, Path}, 0,
                                   [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:close(Client).

%% Criterion 7: after a second start_link on server A's live path fails, server A
%% keeps serving -- the failed second bind did not disturb A's listener, so a
%% fresh client still connects to A.
test_first_server_survives_failed_second_start_link(Config) ->
    Path = socket_path(Config),
    {ok, ServerA} = soma_cli_server:start_link(#{socket => Path}),
    {error, _Reason} = soma_cli_server:start_link(#{socket => Path}),
    true = is_process_alive(ServerA),
    {ok, Client} = gen_tcp:connect({local, Path}, 0,
                                   [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:close(Client).

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
