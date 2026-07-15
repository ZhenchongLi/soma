%% @doc Shared resolution and ownership authority for local Soma socket paths.
-module(soma_socket_path).

-include_lib("kernel/include/file.hrl").

-export([listen/1, close/2, resolve_service/2]).

-define(PROBE_TIMEOUT_MS, 200).
-define(CLAIM_WAIT_ATTEMPTS, 100).
-define(CLAIM_WAIT_MS, 10).
-define(BIND_ATTEMPTS, 8).
-define(FILE_TYPE_MASK, 8#170000).
-define(SOCKET_TYPE, 8#140000).

-type identity() ::
    {non_neg_integer() | undefined,
     non_neg_integer() | undefined,
     non_neg_integer()}.
-opaque ownership_token() ::
    #{path := file:filename_all(), identity := identity()}.

-export_type([ownership_token/0]).

%% @doc Open an AF_UNIX listener without ever replacing a live owner.
%%
%% A failed initial bind is only eligible for stale takeover when the path is
%% an actual socket and a real connection is refused. The contender then owns
%% an exclusive sidecar claim, probes once more, and may unlink only the socket
%% identity observed before it acquired the claim.
-spec listen(file:filename_all()) ->
    {ok, gen_tcp:socket(), ownership_token()} | {error, term()}.
listen(Path) ->
    bind(Path, ?BIND_ATTEMPTS).

%% @doc Close an owned listener and remove its path only if the path still has
%% the identity captured at bind time. A replacement path is left untouched.
-spec close(gen_tcp:socket(), ownership_token()) -> ok | {error, term()}.
close(ListenSocket, Token) ->
    _ = gen_tcp:close(ListenSocket),
    unlink_owned(Token).

%% @doc Resolve a configured service socket, or place the default service.sock
%% beside the already-resolved CLI socket.
-spec resolve_service(file:filename_all(), map()) -> file:filename_all().
resolve_service(_CliPath, #{socket := Socket}) when is_binary(Socket) ->
    unicode:characters_to_list(Socket);
resolve_service(_CliPath, #{socket := Socket}) when is_list(Socket) ->
    Socket;
resolve_service(CliPath, _ServiceConfig) ->
    filename:join(filename:dirname(CliPath), service_basename(CliPath)).

bind(_Path, 0) ->
    {error, address_in_use};
bind(Path, Attempts) ->
    case open_listener(Path) of
        {ok, _ListenSocket, _Token} = Opened ->
            Opened;
        {error, eaddrinuse} ->
            arbitrate_in_use(Path, Attempts);
        {error, Reason} ->
            {error, Reason}
    end.

open_listener(Path) ->
    case gen_tcp:listen(
           0,
           [{ifaddr, {local, Path}}, binary, {packet, raw},
            {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            case socket_identity(Path) of
                {ok, Identity} ->
                    {ok, ListenSocket,
                     #{path => Path, identity => Identity}};
                {error, Reason} ->
                    _ = gen_tcp:close(ListenSocket),
                    {error, {socket_identity, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

arbitrate_in_use(Path, Attempts) ->
    case socket_identity(Path) of
        {ok, StaleIdentity} ->
            case probe(Path) of
                live ->
                    {error, address_in_use};
                refused ->
                    claim_stale(Path, StaleIdentity, Attempts);
                gone ->
                    bind(Path, Attempts - 1);
                unknown ->
                    {error, address_in_use}
            end;
        {error, enoent} ->
            bind(Path, Attempts - 1);
        {error, _NotProvenSocket} ->
            {error, address_in_use}
    end.

claim_stale(Path, StaleIdentity, Attempts) ->
    ClaimPath = claim_path(Path),
    case acquire_claim(ClaimPath) of
        {ok, ClaimToken} ->
            Result =
                try replace_stale(Path, StaleIdentity)
                after
                    _ = unlink_owned(ClaimToken)
                end,
            case Result of
                retry -> bind(Path, Attempts - 1);
                _ -> Result
            end;
        {error, eexist} ->
            case wait_for_claim_release(
                   ClaimPath, ?CLAIM_WAIT_ATTEMPTS) of
                ok -> bind(Path, Attempts - 1);
                {error, _Reason} -> {error, address_in_use}
            end;
        {error, _Reason} ->
            {error, address_in_use}
    end.

replace_stale(Path, StaleIdentity) ->
    case probe(Path) of
        live ->
            {error, address_in_use};
        refused ->
            case owns_path(Path, StaleIdentity) of
                true ->
                    case file:delete(Path) of
                        ok -> open_after_claim(Path);
                        {error, enoent} -> open_after_claim(Path);
                        {error, Reason} -> {error, Reason}
                    end;
                false ->
                    retry
            end;
        gone ->
            open_after_claim(Path);
        unknown ->
            {error, address_in_use}
    end.

%% The sidecar claim is still held here. If another process bound the path in
%% the short unlink-to-bind window, this contender has no cleanup authority for
%% that new path and fails closed.
open_after_claim(Path) ->
    case open_listener(Path) of
        {error, eaddrinuse} -> {error, address_in_use};
        Result -> Result
    end.

probe(Path) ->
    case gen_tcp:connect(
           {local, Path}, 0,
           [binary, {packet, raw}, {active, false}],
           ?PROBE_TIMEOUT_MS) of
        {ok, ProbeSocket} ->
            _ = gen_tcp:close(ProbeSocket),
            live;
        {error, econnrefused} ->
            refused;
        {error, enoent} ->
            gone;
        {error, _Reason} ->
            unknown
    end.

acquire_claim(ClaimPath) ->
    case file:open(ClaimPath, [write, exclusive, raw]) of
        {ok, ClaimFile} ->
            IdentityResult =
                case file:read_file_info(ClaimFile) of
                    {ok, Info} -> {ok, file_identity(Info)};
                    {error, InfoReason} -> {error, InfoReason}
                end,
            _ = file:close(ClaimFile),
            case IdentityResult of
                {ok, Identity} ->
                    {ok, #{path => ClaimPath, identity => Identity}};
                {error, IdentityReason} ->
                    {error, IdentityReason}
            end;
        {error, OpenReason} ->
            {error, OpenReason}
    end.

wait_for_claim_release(_ClaimPath, 0) ->
    {error, claim_in_use};
wait_for_claim_release(ClaimPath, Attempts) ->
    case file:read_link_info(ClaimPath) of
        {error, enoent} ->
            ok;
        {ok, _Info} ->
            timer:sleep(?CLAIM_WAIT_MS),
            wait_for_claim_release(ClaimPath, Attempts - 1);
        {error, Reason} ->
            {error, Reason}
    end.

socket_identity(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = other, mode = Mode} = Info}
          when is_integer(Mode),
               Mode band ?FILE_TYPE_MASK =:= ?SOCKET_TYPE ->
            {ok, file_identity(Info)};
        {ok, _Info} ->
            {error, not_socket};
        {error, Reason} ->
            {error, Reason}
    end.

file_identity(#file_info{major_device = Device,
                         inode = Inode,
                         mode = Mode}) ->
    {Device, Inode, Mode band ?FILE_TYPE_MASK}.

owns_path(Path, ExpectedIdentity) ->
    case file:read_link_info(Path) of
        {ok, Info} -> file_identity(Info) =:= ExpectedIdentity;
        {error, _Reason} -> false
    end.

unlink_owned(#{path := Path, identity := Identity}) ->
    case owns_path(Path, Identity) of
        true ->
            case file:delete(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        false ->
            ok
    end.

claim_path(Path) when is_binary(Path) ->
    <<Path/binary, ".claim">>;
claim_path(Path) ->
    Path ++ ".claim".

service_basename(CliPath) when is_binary(CliPath) ->
    <<"service.sock">>;
service_basename(_CliPath) ->
    "service.sock".
