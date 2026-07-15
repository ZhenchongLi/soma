%% @doc Shared resolution owner for local Soma socket paths.
-module(soma_socket_path).

-export([resolve_service/2]).

%% @doc Resolve a configured service socket, or place the default service.sock
%% beside the already-resolved CLI socket.
-spec resolve_service(file:filename_all(), map()) -> file:filename_all().
resolve_service(_CliPath, #{socket := Socket}) when is_binary(Socket) ->
    unicode:characters_to_list(Socket);
resolve_service(_CliPath, #{socket := Socket}) when is_list(Socket) ->
    Socket;
resolve_service(CliPath, _ServiceConfig) ->
    filename:join(filename:dirname(CliPath), service_basename(CliPath)).

service_basename(CliPath) when is_binary(CliPath) ->
    <<"service.sock">>;
service_basename(_CliPath) ->
    "service.sock".
