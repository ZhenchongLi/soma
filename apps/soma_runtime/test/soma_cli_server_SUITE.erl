-module(soma_cli_server_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_start_link_listens_and_accepts_connect/1]).
-export([test_start_link_unlinks_stale_socket_file/1]).

all() ->
    [test_start_link_listens_and_accepts_connect,
     test_start_link_unlinks_stale_socket_file].

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
